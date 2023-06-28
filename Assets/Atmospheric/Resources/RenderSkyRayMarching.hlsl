// Copyright Epic Games, Inc. All Rights Reserved.

#include "../Resources/RenderSkyCommon.hlsl"

////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////

TEXTURE2D(_CameraDepthTexture);
SAMPLER(sampler_CameraDepthTexture);

struct SingleScatteringResult
{
    float3 L; // Scattered light (luminance)
    float3 OpticalDepth; // Optical depth (1/m)
    float3 Transmittance; // Transmittance in [0,1] (unitless)
    float3 MultiScatAs1;

    float3 NewMultiScatStep0Out;
    float3 NewMultiScatStep1Out;
};

SingleScatteringResult IntegrateScatteredLuminance(
    in float2 uvPos, in float3 WorldPos, in float3 WorldDir, in float3 SunDir, in AtmosphereParameters Atmosphere,
    in bool ground, in float SampleCountIni, in float DepthBufferValue, in bool VariableSampleCount,
    in bool MieRayPhase, in float tMaxMax = 9000000.0f)
{
    // const bool debugEnabled = all(uint2(pixPos.xx) == gMouseLastDownPos.xx) && uint(pixPos.y) % 10 == 0 && DepthBufferValue != -1.0f;
    SingleScatteringResult result = (SingleScatteringResult)0;

    // Compute next intersection with atmosphere or ground 
    float3 earthO = float3(0.0f, 0.0f, 0.0f);
    float tBottom = raySphereIntersectNearest(WorldPos, WorldDir, earthO, Atmosphere.BottomRadius);
    float tTop = raySphereIntersectNearest(WorldPos, WorldDir, earthO, Atmosphere.TopRadius);
    float tMax = 0.0f;
    if (tBottom < 0.0f)
    {
        if (tTop < 0.0f)
        {
            tMax = 0.0f; // No intersection with earth nor atmosphere: stop right away  
            return result;
        }
        else
        {
            tMax = tTop;
        }
    }
    else
    {
        if (tTop > 0.0f)
        {
            tMax = min(tTop, tBottom);
        }
    }

    if (DepthBufferValue >= 0.0f)
    {
        float3 ClipSpace = float3(uvPos * float2(2.0, -2.0) - float2(1.0, -1.0), 0.0);
        #if UNITY_REVERSED_Z
        ClipSpace.z =  DepthBufferValue;
        #endif

        if (ClipSpace.z < 1.0f)
        {
            float4 DepthBufferWorldPos = mul(unity_MatrixInvVP, float4(ClipSpace, 1.0));
            DepthBufferWorldPos /= DepthBufferWorldPos.w;

            float tDepth = length(
                DepthBufferWorldPos.xyz * mPositionScale - (WorldPos + float3(0.0, -Atmosphere.BottomRadius, 0.0)));
            // apply earth offset to go back to origin as top of earth mode. 
            if (tDepth < tMax)
            {
                tMax = tDepth;
            }
        }

    }
    tMax = min(tMax, tMaxMax);
    // Sample count 
    float SampleCount = SampleCountIni;
    float SampleCountFloor = SampleCountIni;
    float tMaxFloor = tMax;
    if (VariableSampleCount)
    {
        SampleCount = lerp(RayMarchMinMaxSPP.x, RayMarchMinMaxSPP.y, saturate(tMax * 0.01));
        SampleCountFloor = floor(SampleCount);
        tMaxFloor = tMax * SampleCountFloor / SampleCount; // rescale tMax to map to the last entire step segment.
    }
    float dt = tMax / SampleCount;

    // Phase functions
    const float uniformPhase = 1.0 / (4.0 * PI);
    const float3 wi = SunDir;
    const float3 wo = WorldDir;
    float cosTheta = dot(wi, wo);
    float MiePhaseValue = hgPhase(Atmosphere.MiePhaseG, -cosTheta);
    // mnegate cosTheta because due to WorldDir being a "in" direction. 
    float RayleighPhaseValue = RayleighPhase(cosTheta);

    #ifdef ILLUMINANCE_IS_ONE
	// When building the scattering factor, we assume light illuminance is 1 to compute a transfert function relative to identity illuminance of 1.
	// This make the scattering factor independent of the light. It is now only linked to the atmosphere properties.
	float3 globalL = 1.0f;
    #else
    float3 globalL = gSunIlluminance;
    #endif

    // Ray march the atmosphere to integrate optical depth
    float3 L = 0.0f;
    float3 throughput = 1.0;
    float3 OpticalDepth = 0.0;
    float t = 0.0f;
    float tPrev = 0.0;
    const float SampleSegmentT = 0.3f;
    for (float s = 0.0f; s < SampleCount; s += 1.0f)
    {
        if (VariableSampleCount)
        {
            // More expenssive but artefact free
            float t0 = (s) / SampleCountFloor;
            float t1 = (s + 1.0f) / SampleCountFloor;
            // Non linear distribution of sample within the range.
            t0 = t0 * t0;
            t1 = t1 * t1;
            // Make t0 and t1 world space distances.
            t0 = tMaxFloor * t0;
            if (t1 > 1.0)
            {
                t1 = tMax;
                //	t1 = tMaxFloor;	// this reveal depth slices
            }
            else
            {
                t1 = tMaxFloor * t1;
            }
            //t = t0 + (t1 - t0) * (whangHashNoise(pixPos.x, pixPos.y, gFrameId * 1920 * 1080)); // With dithering required to hide some sampling artefact relying on TAA later? This may even allow volumetric shadow?
            t = t0 + (t1 - t0) * SampleSegmentT;
            dt = t1 - t0;
        }
        else
        {
            //t = tMax * (s + SampleSegmentT) / SampleCount;
            // Exact difference, important for accuracy of multiple scattering
            float NewT = tMax * (s + SampleSegmentT) / SampleCount;
            dt = NewT - t;
            t = NewT;
        }
        float3 P = WorldPos + t * WorldDir;

        #if DEBUGENABLED
		if (debugEnabled)
		{
			float3 Pprev = WorldPos + tPrev * WorldDir;
			float3 TxToDebugWorld = float3(0, 0, -Atmosphere.BottomRadius);
			addGpuDebugLine(TxToDebugWorld + Pprev, TxToDebugWorld + P, float3(0.2, 1, 0.2));
			addGpuDebugCross(TxToDebugWorld + P, float3(0.2, 0.2, 1.0), 0.2);
		}
        #endif

        MediumSampleRGB medium = sampleMediumRGB(P, Atmosphere);
        const float3 SampleOpticalDepth = medium.extinction * dt;
        const float3 SampleTransmittance = exp(-SampleOpticalDepth);
        OpticalDepth += SampleOpticalDepth;

        float pHeight = length(P);
        const float3 UpVector = P / pHeight;
        float SunZenithCosAngle = dot(SunDir, UpVector);
        float2 uv;
        LutTransmittanceParamsToUv(Atmosphere, pHeight, SunZenithCosAngle, uv);
        float3 TransmittanceToSun = TransmittanceLutTexture.SampleLevel(samplerLinearClamp, uv, 0).rgb;

        float3 PhaseTimesScattering;
        if (MieRayPhase)
        {
            PhaseTimesScattering = medium.scatteringMie * MiePhaseValue + medium.scatteringRay * RayleighPhaseValue;
        }
        else
        {
            PhaseTimesScattering = medium.scattering * uniformPhase;
        }

        // Earth shadow 
        float tEarth = raySphereIntersectNearest(P, SunDir, earthO + PLANET_RADIUS_OFFSET * UpVector,
                                                 Atmosphere.BottomRadius);
        float earthShadow = tEarth >= 0.0f ? 0.0f : 1.0f;

        // Dual scattering for multi scattering 

        float3 multiScatteredLuminance = 0.0f;
        #if MULTISCATAPPROX_ENABLED
		multiScatteredLuminance = GetMultipleScattering(Atmosphere, medium.scattering, medium.extinction, P, SunZenithCosAngle);
        #endif

        float shadow = 1.0f;
        #if SHADOWMAP_ENABLED
		// First evaluate opaque shadow
		shadow = getShadow(Atmosphere, P);
        // result.L = float3(shadow,0,0);
        // return result;

        #endif

        float3 S = globalL * (earthShadow * shadow * TransmittanceToSun * PhaseTimesScattering + multiScatteredLuminance
            * medium.scattering);

        // When using the power serie to accumulate all sattering order, serie r must be <1 for a serie to converge.
        // Under extreme coefficient, MultiScatAs1 can grow larger and thus result in broken visuals.
        // The way to fix that is to use a proper analytical integration as proposed in slide 28 of http://www.frostbite.com/2015/08/physically-based-unified-volumetric-rendering-in-frostbite/
        // However, it is possible to disable as it can also work using simple power serie sum unroll up to 5th order. The rest of the orders has a really low contribution.
        #define MULTI_SCATTERING_POWER_SERIE 1

        #if MULTI_SCATTERING_POWER_SERIE==0
		// 1 is the integration of luminance over the 4pi of a sphere, and assuming an isotropic phase function of 1.0/(4*PI)
		result.MultiScatAs1 += throughput * medium.scattering * 1 * dt;
        #else
        float3 MS = medium.scattering * 1;
        float3 MSint = (MS - MS * SampleTransmittance) / medium.extinction;
        result.MultiScatAs1 += throughput * MSint;
        #endif

        // Evaluate input to multi scattering 
        {
            float3 newMS;

            newMS = earthShadow * TransmittanceToSun * medium.scattering * uniformPhase * 1;
            result.NewMultiScatStep0Out += throughput * (newMS - newMS * SampleTransmittance) / medium.extinction;
            //	result.NewMultiScatStep0Out += SampleTransmittance * throughput * newMS * dt;

            newMS = medium.scattering * uniformPhase * multiScatteredLuminance;
            result.NewMultiScatStep1Out += throughput * (newMS - newMS * SampleTransmittance) / medium.extinction;
            //	result.NewMultiScatStep1Out += SampleTransmittance * throughput * newMS * dt;
        }

        #if 0
		L += throughput * S * dt;
		throughput *= SampleTransmittance;
        #else
        // See slide 28 at http://www.frostbite.com/2015/08/physically-based-unified-volumetric-rendering-in-frostbite/ 
        float3 Sint = (S - S * SampleTransmittance) / medium.extinction; // integrate along the current step segment 
        L += throughput * Sint; // accumulate and also take into account the transmittance from previous steps
        throughput *= SampleTransmittance;
        #endif

        tPrev = t;
    }

    if (ground && tMax == tBottom && tBottom > 0.0)
    {
        // Account for bounced light off the earth
        float3 P = WorldPos + tBottom * WorldDir;
        float pHeight = length(P);

        const float3 UpVector = P / pHeight;
        float SunZenithCosAngle = dot(SunDir, UpVector);
        float2 uv;
        LutTransmittanceParamsToUv(Atmosphere, pHeight, SunZenithCosAngle, uv);
        float3 TransmittanceToSun = TransmittanceLutTexture.SampleLevel(samplerLinearClamp, uv, 0).rgb;

        const float NdotL = saturate(dot(normalize(UpVector), normalize(SunDir)));
        L += globalL * TransmittanceToSun * throughput * NdotL * Atmosphere.GroundAlbedo / PI;
    }

    result.L = L;
    result.OpticalDepth = OpticalDepth;
    result.Transmittance = throughput;
    return result;
}


////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////


#define AP_SLICE_COUNT 64.0f
#define AP_KM_PER_SLICE 0.2f

float AerialPerspectiveDepthToSlice(float depth)
{
    return depth * (1.0f / AP_KM_PER_SLICE);
}

float AerialPerspectiveSliceToDepth(float slice)
{
    return slice * AP_KM_PER_SLICE;
}

struct RayMarchPixelOutputStruct
{
    float4 Luminance : SV_TARGET0;
    #if COLORED_TRANSMITTANCE_ENABLED
	float4 Transmittance	: SV_TARGET1;
    #endif
};

RayMarchPixelOutputStruct RenderRayMarchingPS(VertexOutput Input)
{
    RayMarchPixelOutputStruct output = (RayMarchPixelOutputStruct)0;
    float2 pixPos = Input.position.xy;
    AtmosphereParameters Atmosphere = GetAtmosphereParameters();
    #if UNITY_REVERSED_Z
    float3 ClipSpace = float3(pixPos / gResolution.xy * float2(2.0, -2.0) - float2(1.0, -1.0), 0.0);
    #else
    float3 ClipSpace = float3(pixPos / gResolution.xy * float2(2.0, -2.0) - float2(1.0, -1.0), 1.0);
    #endif

    float4 HViewPos = mul(gSkyInvProjMat, float4(ClipSpace, 1.0));
    float3 WorldDir = normalize(mul((float3x3)gSkyInvViewMat, HViewPos.xyz / HViewPos.w));
    float3 WorldPos = camera + float3(0, Atmosphere.BottomRadius, 0);

    float viewHeight = length(WorldPos);
    float2 uv;
    float3 UpVector = normalize(WorldPos);
    float viewZenithCosAngle = dot(WorldDir, UpVector);

    float3 sideVector = normalize(cross(UpVector, WorldDir)); // assumes non parallel vectors
    float3 forwardVector = normalize(cross(sideVector, UpVector));
    // aligns toward the sun light but perpendicular to up vector
    float2 lightOnPlane = float2(dot(sun_direction, forwardVector), dot(sun_direction, sideVector));
    lightOnPlane = normalize(lightOnPlane);
    float lightViewCosAngle = lightOnPlane.x;

    bool IntersectGround = raySphereIntersectNearest(WorldPos, WorldDir, float3(0, 0, 0), Atmosphere.BottomRadius) >=
        0.0f;

    SkyViewLutParamsToUv(Atmosphere, IntersectGround, viewZenithCosAngle, lightViewCosAngle, viewHeight, uv);

    output.Luminance = float4(
        SkyViewLutTexture.SampleLevel(samplerLinearClamp, uv, 0).rgb + GetSunLuminance(
            WorldPos, WorldDir, Atmosphere.BottomRadius), 1.0);
    return output;
}


////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////
////////////////////////////////////////////////////////////////////////////////


groupshared float3 MultiScatAs1SharedMem[64];
groupshared float3 LSharedMem[64];

[numthreads(1, 1, 64)]
void NewMultiScattCS(uint3 ThreadId : SV_DispatchThreadID)
{
    float2 pixPos = float2(ThreadId.xy) + 0.5f;
    float2 uv = pixPos / MultiScatteringLUTRes;


    uv = float2(fromSubUvsToUnit(uv.x, MultiScatteringLUTRes), fromSubUvsToUnit(uv.y, MultiScatteringLUTRes));

    AtmosphereParameters Atmosphere = GetAtmosphereParameters();

    float cosSunZenithAngle = uv.x * 2.0 - 1.0;
    float3 sunDir = float3(sqrt(saturate(1.0 - cosSunZenithAngle * cosSunZenithAngle)), cosSunZenithAngle, 0.0);
    // We adjust again viewHeight according to PLANET_RADIUS_OFFSET to be in a valid range.
    float viewHeight = Atmosphere.BottomRadius + saturate(uv.y + PLANET_RADIUS_OFFSET) * (Atmosphere.TopRadius -
        Atmosphere.BottomRadius - PLANET_RADIUS_OFFSET);

    float3 WorldPos = float3(0.0f, viewHeight, 0.0f);
    float3 WorldDir = float3(0.0f, 1.0f, 0.0f);


    const bool ground = true;
    const float SampleCountIni = 20; // a minimum set of step is required for accuracy unfortunately
    const float DepthBufferValue = -1.0;
    const bool VariableSampleCount = false;
    const bool MieRayPhase = false;

    const float SphereSolidAngle = 4.0 * PI;
    const float IsotropicPhase = 1.0 / SphereSolidAngle;


    // Reference. Since there are many sample, it requires MULTI_SCATTERING_POWER_SERIE to be true for accuracy and to avoid divergences (see declaration for explanations)
    #define SQRTSAMPLECOUNT 8
    const float sqrtSample = float(SQRTSAMPLECOUNT);
    float i = 0.5f + float(ThreadId.z / SQRTSAMPLECOUNT);
    float j = 0.5f + float(ThreadId.z - float((ThreadId.z / SQRTSAMPLECOUNT) * SQRTSAMPLECOUNT));
    {
        float randA = i / sqrtSample;
        float randB = j / sqrtSample;
        float theta = 2.0f * PI * randA;
        float phi = acos(1.0f - 2.0f * randB);
        // uniform distribution https://mathworld.wolfram.com/SpherePointPicking.html
        //phi = PI * randB;						// bad non uniform
        float cosPhi = cos(phi);
        float sinPhi = sin(phi);
        float cosTheta = cos(theta);
        float sinTheta = sin(theta);
        WorldDir.x = cosTheta * sinPhi;
        WorldDir.y = sinTheta * sinPhi;
        WorldDir.z = cosPhi;
        SingleScatteringResult result = IntegrateScatteredLuminance(uv, WorldPos, WorldDir, sunDir, Atmosphere,
                                                                    ground, SampleCountIni, DepthBufferValue,
                                                                    VariableSampleCount, MieRayPhase);

        MultiScatAs1SharedMem[ThreadId.z] = result.MultiScatAs1 * SphereSolidAngle / (sqrtSample * sqrtSample);
        LSharedMem[ThreadId.z] = result.L * SphereSolidAngle / (sqrtSample * sqrtSample);
    }
    #undef SQRTSAMPLECOUNT

    GroupMemoryBarrierWithGroupSync();

    // 64 to 32
    if (ThreadId.z < 32)
    {
        MultiScatAs1SharedMem[ThreadId.z] += MultiScatAs1SharedMem[ThreadId.z + 32];
        LSharedMem[ThreadId.z] += LSharedMem[ThreadId.z + 32];
    }
    GroupMemoryBarrierWithGroupSync();

    // 32 to 16
    if (ThreadId.z < 16)
    {
        MultiScatAs1SharedMem[ThreadId.z] += MultiScatAs1SharedMem[ThreadId.z + 16];
        LSharedMem[ThreadId.z] += LSharedMem[ThreadId.z + 16];
    }
    GroupMemoryBarrierWithGroupSync();

    // 16 to 8 (16 is thread group min hardware size with intel, no sync required from there)
    if (ThreadId.z < 8)
    {
        MultiScatAs1SharedMem[ThreadId.z] += MultiScatAs1SharedMem[ThreadId.z + 8];
        LSharedMem[ThreadId.z] += LSharedMem[ThreadId.z + 8];
    }
    GroupMemoryBarrierWithGroupSync();
    if (ThreadId.z < 4)
    {
        MultiScatAs1SharedMem[ThreadId.z] += MultiScatAs1SharedMem[ThreadId.z + 4];
        LSharedMem[ThreadId.z] += LSharedMem[ThreadId.z + 4];
    }
    GroupMemoryBarrierWithGroupSync();
    if (ThreadId.z < 2)
    {
        MultiScatAs1SharedMem[ThreadId.z] += MultiScatAs1SharedMem[ThreadId.z + 2];
        LSharedMem[ThreadId.z] += LSharedMem[ThreadId.z + 2];
    }
    GroupMemoryBarrierWithGroupSync();
    if (ThreadId.z < 1)
    {
        MultiScatAs1SharedMem[ThreadId.z] += MultiScatAs1SharedMem[ThreadId.z + 1];
        LSharedMem[ThreadId.z] += LSharedMem[ThreadId.z + 1];
    }
    GroupMemoryBarrierWithGroupSync();
    if (ThreadId.z > 0)
        return;

    float3 MultiScatAs1 = MultiScatAs1SharedMem[0] * IsotropicPhase; // Equation 7 f_ms
    float3 InScatteredLuminance = LSharedMem[0] * IsotropicPhase; // Equation 5 L_2ndOrder

    // MultiScatAs1 represents the amount of luminance scattered as if the integral of scattered luminance over the sphere would be 1.
    //  - 1st order of scattering: one can ray-march a straight path as usual over the sphere. That is InScatteredLuminance.
    //  - 2nd order of scattering: the inscattered luminance is InScatteredLuminance at each of samples of fist order integration. Assuming a uniform phase function that is represented by MultiScatAs1,
    //  - 3nd order of scattering: the inscattered luminance is (InScatteredLuminance * MultiScatAs1 * MultiScatAs1)
    //  - etc.
    #if	MULTI_SCATTERING_POWER_SERIE==0
	float3 MultiScatAs1SQR = MultiScatAs1 * MultiScatAs1;
	float3 L = InScatteredLuminance * (1.0 + MultiScatAs1 + MultiScatAs1SQR + MultiScatAs1 * MultiScatAs1SQR + MultiScatAs1SQR * MultiScatAs1SQR);
    #else
    // For a serie, sum_{n=0}^{n=+inf} = 1 + r + r^2 + r^3 + ... + r^n = 1 / (1.0 - r), see https://en.wikipedia.org/wiki/Geometric_series 
    const float3 r = MultiScatAs1;
    const float3 SumOfAllMultiScatteringEventsContribution = 1.0f / (1.0 - r);
    float3 L = InScatteredLuminance * SumOfAllMultiScatteringEventsContribution; // Equation 10 Psi_ms
    #endif

    OutputTexture[ThreadId.xy] = float4(MultipleScatteringFactor * L, 1.0f);
}
