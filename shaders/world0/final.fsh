#version 120
//Vignetting, applies bloom, applies exposure and tonemaps the final image
#extension GL_EXT_gpu_shader4 : enable

#include "/lib/settings.glsl"

varying vec2 texcoord;

uniform sampler2D colortex2;

uniform vec2 texelSize;

uniform float rainStrength;
uniform float viewWidth;
uniform float viewHeight;
uniform float frameTimeCounter;
uniform float sunAngle;					   
uniform int frameCounter;
uniform sampler2D colortex1;//albedo(rgb),material(alpha) RGBA16
uniform int isEyeInWater;
#include "/lib/color_transforms.glsl"
#include "/lib/color_dither.glsl"
#include "/lib/encode.glsl"
#include "/lib/res_params.glsl"
vec4 SampleTextureCatmullRom(sampler2D tex, vec2 uv, vec2 texSize )
{
    // We're going to sample a a 4x4 grid of texels surrounding the target UV coordinate. We'll do this by rounding
    // down the sample location to get the exact center of our "starting" texel. The starting texel will be at
    // location [1, 1] in the grid, where [0, 0] is the top left corner.
    vec2 samplePos = uv * texSize;
    vec2 texPos1 = floor(samplePos - 0.5) + 0.5;

    // Compute the fractional offset from our starting texel to our original sample location, which we'll
    // feed into the Catmull-Rom spline function to get our filter weights.
    vec2 f = samplePos - texPos1;

    // Compute the Catmull-Rom weights using the fractional offset that we calculated earlier.
    // These equations are pre-expanded based on our knowledge of where the texels will be located,
    // which lets us avoid having to evaluate a piece-wise function.
    vec2 w0 = f * ( -0.5 + f * (1.0 - 0.5*f));
    vec2 w1 = 1.0 + f * f * (-2.5 + 1.5*f);
    vec2 w2 = f * ( 0.5 + f * (2.0 - 1.5*f) );
    vec2 w3 = f * f * (-0.5 + 0.5 * f);

    // Work out weighting factors and sampling offsets that will let us use bilinear filtering to
    // simultaneously evaluate the middle 2 samples from the 4x4 grid.
    vec2 w12 = w1 + w2;
    vec2 offset12 = w2 / (w1 + w2);

    // Compute the final UV coordinates we'll use for sampling the texture
    vec2 texPos0 = texPos1 - vec2(1.0);
    vec2 texPos3 = texPos1 + vec2(2.0);
    vec2 texPos12 = texPos1 + offset12;

    texPos0 *= texelSize;
    texPos3 *= texelSize;
    texPos12 *= texelSize;

    vec4 result = vec4(0.0);
    result += texture2D(tex, vec2(texPos0.x,  texPos0.y)) * w0.x * w0.y;
    result += texture2D(tex, vec2(texPos12.x, texPos0.y)) * w12.x * w0.y;
    result += texture2D(tex, vec2(texPos3.x,  texPos0.y)) * w3.x * w0.y;

    result += texture2D(tex, vec2(texPos0.x,  texPos12.y)) * w0.x * w12.y;
    result += texture2D(tex, vec2(texPos12.x, texPos12.y)) * w12.x * w12.y;
    result += texture2D(tex, vec2(texPos3.x,  texPos12.y)) * w3.x * w12.y;

    result += texture2D(tex, vec2(texPos0.x,  texPos3.y)) * w0.x * w3.y;
    result += texture2D(tex, vec2(texPos12.x, texPos3.y)) * w12.x * w3.y;
    result += texture2D(tex, vec2(texPos3.x,  texPos3.y)) * w3.x * w3.y;

    return result;
}

	vec3 doChromaticAberration(vec2 coord) {

		const float offsetMultiplier	= 0.002;

		float dist = pow(distance(coord.st, vec2(0.5)), 2.5);

		vec3 color = vec3(0.0);

		color.r = texture2D(colortex2, coord.st + vec2(offsetMultiplier * dist, 0.0)).r;
		color.g = texture2D(colortex2, coord.st).g;
		color.b = texture2D(colortex2, coord.st - vec2(offsetMultiplier * dist, 0.0)).b;

		return color;

	}

	vec3 vignette(vec3 color) {

		float vignetteStrength	= 1.0;
		float vignetteSharpness	= 3.0;

		float dist = 1.0 - pow(distance(texcoord.st, vec2(0.5)), vignetteSharpness) * vignetteStrength;

		return color * dist;

	}

	
	
	float rand(vec2 coord) {
	  return fract(sin(dot(coord.xy, vec2(12.9898, 78.233))) * 43758.5453);
	}

	vec3 filmgrain(vec3 color) {

		const float noiseAmount = 0.03;

		vec2 coord = texcoord + frameTimeCounter * 0.01;

		vec3 noise = vec3(0.0);
				 noise.r = rand(coord + 0.1);
				 noise.g = rand(coord);
				 noise.b = rand(coord - 0.1);

		return color * (1.0 - noiseAmount + noise * noiseAmount) + noise * noiseAmount;

	}	
	
	
	
void main() {
  #ifdef BICUBIC_UPSCALING
    vec3 col = SampleTextureCatmullRom(colortex2,texcoord,1.0/texelSize).rgb;
  #else
    vec3 col = texture2D(colortex2,texcoord).rgb;
  #endif
  #ifdef CHROMATIC  
	     col = doChromaticAberration(texcoord); 
  #endif
  #ifdef GRAIN  
		col = filmgrain(col);
  #endif
  #ifdef VIGNETTE
		 col = vignette(col);
  #endif
 	 
		 
  #ifdef CONTRAST_ADAPTATIVE_SHARPENING
    //Weights : 1 in the center, 0.5 middle, 0.25 corners
    vec3 albedoCurrent1 = texture2D(colortex2, texcoord + vec2(texelSize.x,texelSize.y)/MC_RENDER_QUALITY*0.5).rgb;
    vec3 albedoCurrent2 = texture2D(colortex2, texcoord + vec2(texelSize.x,-texelSize.y)/MC_RENDER_QUALITY*0.5).rgb;
    vec3 albedoCurrent3 = texture2D(colortex2, texcoord + vec2(-texelSize.x,-texelSize.y)/MC_RENDER_QUALITY*0.5).rgb;
    vec3 albedoCurrent4 = texture2D(colortex2, texcoord + vec2(-texelSize.x,texelSize.y)/MC_RENDER_QUALITY*0.5).rgb;


    vec3 m1 = -0.5/3.5*col + albedoCurrent1/3.5 + albedoCurrent2/3.5 + albedoCurrent3/3.5 + albedoCurrent4/3.5;
    vec3 std = abs(col - m1) + abs(albedoCurrent1 - m1) + abs(albedoCurrent2 - m1) +
     abs(albedoCurrent3 - m1) + abs(albedoCurrent3 - m1) + abs(albedoCurrent4 - m1);
    float contrast = 1.0 - luma(std)/5.0;
    col = col*(1.0+(SHARPENING+UPSCALING_SHARPNENING)*contrast)
          - (SHARPENING+UPSCALING_SHARPNENING)/(1.0-0.5/3.5)*contrast*(m1 - 0.5/3.5*col);
  #endif
						
  float lum = luma(col);
  vec3 diff = col-lum;
  col = col + diff*(-lum*CROSSTALK + SATURATION);


	gl_FragColor.rgb = clamp(int8Dither(col,texcoord),0.0,1.0);

}
