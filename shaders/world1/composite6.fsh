#version 120
//Horizontal bilateral blur for volumetric fog + Forward rendered objects + Draw volumetric fog
#extension GL_EXT_gpu_shader4 : enable
#include "/lib/settings.glsl"


varying vec2 texcoord;
flat varying vec3 WsunVec;
flat varying vec3 ambientUp;
flat varying vec3 ambientLeft;
flat varying vec3 ambientRight;
flat varying vec3 ambientB;
flat varying vec3 ambientF;
flat varying vec3 ambientDown;
flat varying vec3 zMults;
flat varying vec4 lightCol;
flat varying float fogAmount;
uniform sampler2D depthtex0;
uniform sampler2D colortex7;
uniform sampler2D colortex3;
uniform sampler2D colortex2;
uniform sampler2D colortex0;
uniform sampler2D noisetex;
uniform sampler2D gdepthtex;
uniform float sunElevation;
uniform float frameTimeCounter;
uniform int frameCounter;
uniform float far;
uniform float near;
uniform int isEyeInWater;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferProjectionInverse;
uniform vec2 texelSize;
uniform vec3 cameraPosition;
uniform ivec2 eyeBrightnessSmooth;
uniform vec3 sunVec;
#include "/lib/waterBump.glsl"
float ld(float depth) {
    return 1.0 / (zMults.y - depth * zMults.z);		// (-depth * (far - near)) = (2.0 * near)/ld - far - near
}

vec2 newtc = texcoord.xy;
	float GetDepthLinear(in vec2 coord) { //Function that retrieves the scene depth. 0 - 1, higher values meaning farther away
		return 1.0f * near * far / (far + near - (1.91f * texture2D(gdepthtex, coord).x - 1.0f) * (far - near));
}

#define diagonal3(m) vec3((m)[0].x, (m)[1].y, m[2].z)
#define  projMAD(m, v) (diagonal3(m) * (v) + (m)[3].xyz)
vec3 toScreenSpace(vec3 p) {
	vec4 iProjDiag = vec4(gbufferProjectionInverse[0].x, gbufferProjectionInverse[1].y, gbufferProjectionInverse[2].zw);
    vec3 p3 = p * 2. - 1.;
    vec4 fragposition = iProjDiag * p3.xyzz + gbufferProjectionInverse[3];
    return fragposition.xyz / fragposition.w;
}
float phaseRayleigh(float cosTheta) {
	const vec2 mul_add = vec2(0.1, 0.28) /acos(-1.0);
	return cosTheta * mul_add.x + mul_add.y; // optimized version from [Elek09], divided by 4 pi for energy conservation
}
float phaseg(float x, float g){
    float gg = g * g;
    return (gg * -0.25 + 0.25) * pow(-2.0 * (g * x) + (gg + 1.0), -1.5) /3.1415;
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
			float densityVol = cloudVol(progressW);
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
float R2_dither(){
	vec2 alpha = vec2(0.75487765, 0.56984026);
	return fract(alpha.x * gl_FragCoord.x + alpha.y * gl_FragCoord.y + 0.43015971 * frameCounter);
}

	
void main() {
  /* DRAWBUFFERS:3 */
  //3x3 bilateral upscale from half resolution
  float z = texture2D(depthtex0,texcoord).x;
  vec3 fragpos = toScreenSpace(vec3(texcoord-vec2(0.0)*texelSize*0.5,z));
  vec4 transparencies = texture2D(colortex2,texcoord);
  vec4 trpData = texture2D(colortex7,texcoord);
  bool iswater = trpData.a > 0.99;
  vec2 refractedCoord = texcoord;

  if (iswater){

  	vec3 np3 = mat3(gbufferModelViewInverse) * fragpos + gbufferModelViewInverse[3].xyz + cameraPosition;
    float norm = getWaterHeightmap(np3.xz*1.71, 4.0, 0.25, 1.0);
    float displ = norm/(length(fragpos)/far)/35.;
    refractedCoord += displ;

    if (texture2D(colortex7,refractedCoord).a < 0.99)
      refractedCoord = texcoord;

  }
  vec3 color = texture2D(colortex3,refractedCoord).rgb;
  if (length(fragpos) > 0.2 || transparencies.a < 0.99)  // Discount fix for transparencies through hand
    color = color*(1.0-transparencies.a)+transparencies.rgb*10.;

  float dirtAmount = Dirt_Amount;
	vec3 waterEpsilon = vec3(Water_Absorb_R, Water_Absorb_G, Water_Absorb_B);
	vec3 dirtEpsilon = vec3(Dirt_Absorb_R, Dirt_Absorb_G, Dirt_Absorb_B);
	vec3 totEpsilon = dirtEpsilon*dirtAmount + waterEpsilon;
	vec3 scatterCoef = dirtAmount * vec3(Dirt_Scatter_R, Dirt_Scatter_G, Dirt_Scatter_B) / 3.1415;

  if (isEyeInWater == 0){
    mat2x3 vl = getVolumetricRays(R2_dither(),fragpos);
    color *= vl[1];
    color += vl[0];
  }
  if (isEyeInWater == 1){
    vec3 fragpos = toScreenSpace(vec3(texcoord-vec2(0.0)*texelSize*0.5,z));
    color.rgb *= exp(-length(fragpos)*totEpsilon);
    float estEyeDepth = clamp((14.0-eyeBrightnessSmooth.y/255.0*16.0)/14.0,0.,1.0);
    estEyeDepth *= estEyeDepth*estEyeDepth*34.0;
    #ifndef lightMapDepthEstimation
      estEyeDepth = max(Water_Top_Layer - cameraPosition.y,0.0);
    #endif
    vec3 vl = vec3(0.0);
    waterVolumetrics(vl, vec3(0.0), fragpos, estEyeDepth, estEyeDepth, length(fragpos), R2_dither(), totEpsilon, scatterCoef, ambientUp*8./150./3.*0.84*2.0/3.1415, lightCol.rgb*8./150./3.0*(0.91-pow(1.0-sunElevation,5.0)*0.86), dot(normalize(fragpos), normalize(sunVec)));
    color += vl;
  }
	if(isEyeInWater == 2) {
		float depth = texture2D(depthtex0, newtc).r;

		vec3 fogColor = pow(vec3(255, 87, 0) / 255.0, vec3(2.5));

		color = mix(color, fogColor, min(GetDepthLinear(texcoord.st) * 590.0 / far, 1.0))*2;
	}
  
  
  gl_FragData[0].rgb = clamp(color,6.11*1e-5,65000.0);
}