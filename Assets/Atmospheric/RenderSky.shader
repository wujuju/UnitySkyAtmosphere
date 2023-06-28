Shader "Universal Render Pipeline/RenderSky"
{
    SubShader
    {

        Tags
        {
            "Queue" = "Background" "RenderType" = "Background" "RenderPipeline" = "UniversalPipeline" "PreviewType" = "Skybox"
        }
        ZWrite Off Cull Off
//        ZTest Off

        Pass
        {
            HLSLPROGRAM


            #include "Resources/RenderSkyRayMarching.hlsl"
            #pragma vertex ScreenTriangleVertexShader
            #pragma fragment RenderRayMarchingPS
            ENDHLSL
        }
    }
}