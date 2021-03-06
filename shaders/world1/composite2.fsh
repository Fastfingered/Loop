#version 120
//Volumetric fog rendering
#extension GL_EXT_gpu_shader4 : enable

#include "/lib/settings.glsl"

flat varying vec4 lightCol;
flat varying vec3 ambientUp;
flat varying vec3 ambientLeft;
flat varying vec3 ambientRight;
flat varying vec3 ambientB;
flat varying vec3 ambientF;
flat varying vec3 ambientDown;
flat varying float tempOffsets;
flat varying float fogAmount;
flat varying float VFAmount;
uniform sampler2D noisetex;
uniform sampler2D depthtex0;
uniform vec3 fogColor;


uniform float fogDensity;
uniform float blindness; 


uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler2D colortex4;

uniform vec3 sunVec;
uniform float far;
uniform int frameCounter;
uniform float rainStrength;
uniform float sunElevation;
uniform ivec2 eyeBrightnessSmooth;
uniform float frameTimeCounter;
uniform int isEyeInWater;
uniform vec2 texelSize;
#include "/lib/color_transforms.glsl"
#include "/lib/color_dither.glsl"
#include "/lib/projections.glsl"
#include "/lib/sky_gradient.glsl"
#include "/lib/res_params.glsl"		
#define fsign(a)  (clamp((a)*1e35,0.,1.)*2.-1.)

float interleaved_gradientNoise(){
	return fract(52.9829189*fract(0.06711056*gl_FragCoord.x + 0.00583715*gl_FragCoord.y)+tempOffsets);
}


float phaseg(float x, float g){
    float gg = g * g;
    return (gg * -0.25 + 0.25) * pow(-2.0 * (g * x) + (gg + 1.0), -1.5) /3.14;
}
float phaseRayleigh(float cosTheta) {
	const vec2 mul_add = vec2(0.1, 0.28) /acos(-1.0);
	return cosTheta * mul_add.x + mul_add.y; // optimized version from [Elek09], divided by 4 pi for energy conservation
}

float densityAtPos(in vec3 pos)
{

	pos /= 18.;
	pos.xz *= 0.5;


	vec3 p = floor(pos);
	vec3 f = fract(pos);

	f = (f*f) * (3.-2.*f);

	vec2 uv =  p.xz + f.xz + p.y * vec2(0.0,193.0);

	vec2 coord =  uv / 512.0;

	vec2 xy = texture2D(noisetex, coord).yx;

	return mix(xy.r,xy.g, f.y);
}
float cloudVol(in vec3 pos){

	vec3 samplePos = pos*vec3(1.0,3./64.,1.0)*5.0+frameTimeCounter*vec3(10,-0.1,10)*2.;
										 
	float coverage = clamp(exp(-max(pos.y-300,-20.0)/80.0),0.0,1);
	float noise = densityAtPos(samplePos*2);

	float cloud = pow(clamp(coverage-noise-0.76,0.0,1.0),2.)*(coverage+0.01);

return cloud;
}
mat2x3 getVolumetricRays(float dither,vec3 fragpos) {

														
	vec3 wpos = mat3(gbufferModelViewInverse) * fragpos + gbufferModelViewInverse[3].xyz;



													 
											   


											
																	
																		 

	vec3 dVWorld = (wpos-gbufferModelViewInverse[3].xyz);

	float maxLength = clamp(min(length(dVWorld),far)/length(dVWorld),0.0,far);

	dVWorld *= maxLength;

			   
						   
	vec3 progressW = gbufferModelViewInverse[3].xyz+cameraPosition;
	vec3 vL = vec3(0.);

	float SdotV = dot(sunVec,normalize(fragpos))*lightCol.a;
	float dL = length(dVWorld);
	//Mie phase + somewhat simulates multiple scattering (Horizon zero down cloud approx)
	float mie = max(phaseg(SdotV,E_fog_mieg1),1.0/13.0);
	float rayL = phaseRayleigh(SdotV);
	wpos.y = clamp(wpos.y,0.0,1.0);

	vec3 ambientCoefs = dVWorld/dot(abs(dVWorld),vec3(1.));

	vec3 ambientLight = ambientUp*clamp(ambientCoefs.y,0.,1.);
	ambientLight += ambientDown*clamp(-ambientCoefs.y,0.,1.);
	ambientLight += ambientRight*clamp(ambientCoefs.x,0.,1.);
	ambientLight += ambientLeft*clamp(-ambientCoefs.x,0.,1.);
	ambientLight += ambientB*clamp(ambientCoefs.z,0.,1.);
	ambientLight += ambientF*clamp(-ambientCoefs.z,0.,1.);

	vec3 skyCol0 = ambientLight*8.*2./150./3.*eyeBrightnessSmooth.y/vec3(240.)*E_Ambient_Mult*2.0/3.1415;


	vec3 rC = vec3(E_fog_coefficientRayleighR*1e-6, E_fog_coefficientRayleighG*1e-5, E_fog_coefficientRayleighB*1e-5);
	vec3 mC = vec3(E_fog_coefficientMieR*1e-6, E_fog_coefficientMieG*1e-6, E_fog_coefficientMieB*1e-6);


		float mu = 1.0;
		float muS = 1.05;
		vec3 absorbance = vec3(1.0);
		float expFactor = 11.0;
	for (int i=0;i<E_VL_SAMPLES;i++) {
		float d = (pow(expFactor, float(i+dither)/float(E_VL_SAMPLES))/expFactor - 1.0/expFactor)/(1-1.0/expFactor);
		float dd = pow(expFactor, float(i+dither)/float(E_VL_SAMPLES)) * log(expFactor) / float(E_VL_SAMPLES)/(expFactor-1.0);
		progressW = gbufferModelViewInverse[3].xyz+cameraPosition + d*dVWorld;
			float densityVol = cloudVol(progressW)+(100*blindness);
			float density = densityVol;
			vec3 vL0 = skyCol0*density*muS;
			vL += (vL0 - vL0 * exp(-density*mu*dd*dL)) / (density*mu+0.00000001)*absorbance;
			absorbance *= clamp(exp(-density*mu*dd*dL),0.0,1.0);
		}
	return mat2x3(vL,absorbance);



}
void waterVolumetrics(inout vec3 inColor, vec3 rayStart, vec3 rayEnd, float estEyeDepth, float estSunDepth, float rayLength, float dither, vec3 waterCoefs, vec3 scatterCoef, vec3 ambient, vec3 lightSource, float VdotL){
		int spCount = 6;
		//limit ray length at 32 blocks for performance and reducing integration error
		//you can't see above this anyway
		float maxZ = min(rayLength,32.0)/(1e-8+rayLength);
		rayLength *= maxZ;
		float dY = normalize(mat3(gbufferModelViewInverse) * rayEnd).y * rayLength;
		vec3 absorbance = vec3(1.0);
		vec3 vL = vec3(0.0);
		float phase = phaseg(VdotL, Dirt_Mie_Phase);
		float expFactor = 11.0;
		for (int i=0;i<spCount;i++) {
			float d = (pow(expFactor, float(i+dither)/float(spCount))/expFactor - 1.0/expFactor)/(1-1.0/expFactor);		// exponential step position (0-1)
			float dd = pow(expFactor, float(i+dither)/float(spCount)) * log(expFactor) / float(spCount)/(expFactor-1.0);	//step length (derivative)
			vec3 ambientMul = exp(-max(estEyeDepth - dY * d,0.0) * waterCoefs * 1.1);
			vec3 sunMul = exp(-max((estEyeDepth - dY * d) ,0.0)/abs(sunElevation) * waterCoefs);
			vec3 light = (0.75 * lightSource * phase * sunMul + ambientMul*ambient )*scatterCoef;
			vL += (light - light * exp(-waterCoefs * dd * rayLength)) / waterCoefs *absorbance;
			absorbance *= exp(-dd * rayLength * waterCoefs);
		}
		inColor += vL;
}
float blueNoise(){
  return fract(texelFetch2D(noisetex, ivec2(gl_FragCoord.xy)%512, 0).a + 1.0/1.6180339887 * frameCounter);
}
//////////////////////////////VOID MAIN//////////////////////////////
//////////////////////////////VOID MAIN//////////////////////////////
//////////////////////////////VOID MAIN//////////////////////////////
//////////////////////////////VOID MAIN//////////////////////////////
//////////////////////////////VOID MAIN//////////////////////////////

void main() {
/* DRAWBUFFERS:0 */
	if (isEyeInWater == 0){
		vec2 tc = floor(gl_FragCoord.xy)*2.0*texelSize+0.5*texelSize;
		float z = texture2D(depthtex0,tc).x;
		vec3 fragpos = toScreenSpace(vec3(tc/RENDER_SCALE,z));
		float noise=blueNoise();
		mat2x3 vl = getVolumetricRays(noise,fragpos);
		float absorbance = dot(vl[1],vec3(0.22,0.71,0.07));
		gl_FragData[0] = clamp(vec4(vl[0],absorbance),0.000001,65000.);
	}
	else {
		float dirtAmount = Dirt_Amount;
		vec3 waterEpsilon = vec3(Water_Absorb_R, Water_Absorb_G, Water_Absorb_B);
		vec3 dirtEpsilon = vec3(Dirt_Absorb_R, Dirt_Absorb_G, Dirt_Absorb_B);
		vec3 totEpsilon = dirtEpsilon*dirtAmount + waterEpsilon;
		vec3 scatterCoef = dirtAmount * vec3(Dirt_Scatter_R, Dirt_Scatter_G, Dirt_Scatter_B) / pi;
		vec2 tc = floor(gl_FragCoord.xy)*2.0*texelSize+0.5*texelSize;
		float z = texture2D(depthtex0,tc).x;
		vec3 fragpos = toScreenSpace(vec3(tc/RENDER_SCALE,z));
		float noise=blueNoise();
		vec3 vl = vec3(0.0);
		float estEyeDepth = clamp((14.0-eyeBrightnessSmooth.y/255.0*16.0)/14.0,0.,1.0);
		estEyeDepth *= estEyeDepth*estEyeDepth*34.0;
		#ifndef lightMapDepthEstimation
			estEyeDepth = max(Water_Top_Layer - cameraPosition.y,0.0);
		#endif
		waterVolumetrics(vl, vec3(0.0), fragpos, estEyeDepth, estEyeDepth, length(fragpos), noise, totEpsilon, scatterCoef, ambientUp*8./150./3.*0.84*2.0/pi, lightCol.rgb*8./150./3.0*(0.91-pow(1.0-sunElevation,5.0)*0.86), dot(normalize(fragpos), normalize(sunVec)));
		gl_FragData[0] = clamp(vec4(vl,1.0),0.000001,65000.);
	}

}
