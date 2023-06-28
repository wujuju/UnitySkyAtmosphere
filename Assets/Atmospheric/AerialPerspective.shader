Shader "Universal Render Pipeline/AerialPerspective"
{
    SubShader
    {
        Cull Off ZWrite Off ZTest Always

        Pass
        {
            HLSLPROGRAM
            #pragma multi_compile _ FASTAERIALPERSPECTIVE_ENABLED
            #pragma multi_compile _ MULTISCATAPPROX_ENABLED
            #pragma multi_compile _ SHADOWMAP_ENABLED
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS
            #pragma multi_compile _ _MAIN_LIGHT_SHADOWS_CASCADE
            #include "Resources/RenderSkyRayMarching.hlsl"

            #pragma vertex vert
            #pragma fragment frag
            SAMPLER(sampler_LinearClamp);
            Texture2D _MainTex;

            struct appdata
            {
                float4 vertex : POSITION;
                float2 uv : TEXCOORD0;
            };

            struct v2f
            {
                float2 uv : TEXCOORD0;
                float4 vertex : SV_POSITION;
            };

            v2f vert(appdata v)
            {
                v2f o;
                o.vertex = TransformObjectToHClip(v.vertex);
                o.uv = v.uv;
                return o;
            }

            float4 frag(v2f i) : SV_Target
            {
                float2 uv = i.uv;
                float4 sceneColor = _MainTex.SampleLevel(sampler_LinearClamp, uv, 0);
                float DepthBufferValue = SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, sampler_LinearClamp, uv);
                float3 ClipSpace = float3(uv * float2(2.0, -2.0) - float2(1.0, -1.0), DepthBufferValue);

                #if UNITY_REVERSED_Z
                if (DepthBufferValue == 0) return sceneColor;
                #else
                if(DepthBufferValue == 1.0) return sceneColor;
                #endif

                #ifdef FASTAERIALPERSPECTIVE_ENABLED
                float4 DepthBufferWorldPos = mul(unity_MatrixInvVP, float4(ClipSpace, 1.0));
                DepthBufferWorldPos /= DepthBufferWorldPos.w;
                float tDepth = length(DepthBufferWorldPos.xyz * mPositionScale - camera);
                float Slice = AerialPerspectiveDepthToSlice(tDepth);
                float Weight = 1.0;

                if (Slice < 0.5)
                {
                    // We multiply by weight to fade to 0 at depth 0. That works for luminance and opacity.
                    Weight = saturate(Slice * 2.0);
                    Slice = 0.5;
                }
                float w = sqrt(Slice / AP_SLICE_COUNT); // squared distribution

                float4 AP = Weight * AtmosphereCameraScatteringVolume.SampleLevel(
                    sampler_LinearClamp, float3(uv, w), 0);
                sceneColor = float4((sceneColor.rgb+AP.rgb),AP.a);
                #endif

                #ifdef SHADOWMAP_ENABLED
                const bool ground = false;
                const float SampleCountIni = 0.0f;
                const bool VariableSampleCount = true;
                const bool MieRayPhase = true;
                AtmosphereParameters Atmosphere = GetAtmosphereParameters();
                float3 WorldPos = camera + float3(0, Atmosphere.BottomRadius, 0);
                ClipSpace.z = 1;
                float4 HViewPos = mul(gSkyInvProjMat, float4(ClipSpace, 1.0));
                float3 WorldDir = normalize(mul((float3x3)gSkyInvViewMat, HViewPos.xyz / HViewPos.w));
                SingleScatteringResult ss = IntegrateScatteredLuminance(uv, WorldPos, WorldDir, sun_direction,
                                                                        Atmosphere,
                                                                        ground, SampleCountIni, DepthBufferValue,
                                                                        VariableSampleCount, MieRayPhase);
                float3 throughput = ss.Transmittance;
                const float Transmittance = dot(throughput, float3(1.0f / 3.0f, 1.0f / 3.0f, 1.0f / 3.0f));
                sceneColor=float4(sceneColor.rgb+ss.L,(1-Transmittance));
                #endif


                return sceneColor;
            }
            ENDHLSL
        }
    }
}