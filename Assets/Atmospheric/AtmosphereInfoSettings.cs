using System;
using System.Collections;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using Unity.Collections;
using Unity.VisualScripting;
using UnityEngine;
using UnityEngine.Rendering;
using UnityEngine.Rendering.Universal;
using UnityEngine.Serialization;

public class AtmosphereInfoSettings : MonoBehaviour
{
    private ComputeBuffer constantBuffer;

    public Light mainLight;
    [Range(0, 10.0f)] public float EarthRayleighScaleHeight = 8.0f;
    [Range(0, 10.0f)] public float EarthMieScaleHeight = 1.2f;
    [Range(0, 5.0f)] public float currentMultipleScatteringFactor = 1.0f;
    [Range(0, 1.0f)] public float sun_angular_radius = 0.004675f;
    [Range(0, 0.999f)] public float mie_phase_function_g = 0.8f;
    [Range(0, 10.0f)] public float RayleighScatScale = 1.0f;
    [Range(0, 5.0f)] public float mSunIlluminanceScale = 1.0f;

    const int MultiScatteringLUTRes = 32;
    const float EarthBottomRadius = 6360.0f;
    const float EarthTopRadius = 6460.0f;
    private CommonConstantBufferStructure mConstantBufferCPU = new CommonConstantBufferStructure();
    public SkyAtmosphereConstantBufferStructure cb = new SkyAtmosphereConstantBufferStructure();
    private Material renderSkyMat;
    private float scale = 1 / 1000f;
    public bool currentMultiscatapprox = true;
    public bool currentAerialPerspective = true;
    public bool currentShadowmap = true;
    private Camera camera;
    public static bool isAwake = false;

    void Start()
    {
        isAwake = true;
        camera = Camera.main;
        renderSkyMat = new Material(Shader.Find("Universal Render Pipeline/RenderSky"));
        RenderSettings.skybox = renderSkyMat;
    }

    private void OnDestroy()
    {
        isAwake = false;
    }

    void UpdateConstantBuff()
    {
        if (currentAerialPerspective)
            AerialPerspectiveRenderFeature.material.EnableKeyword("FASTAERIALPERSPECTIVE_ENABLED");
        else
            AerialPerspectiveRenderFeature.material.DisableKeyword("FASTAERIALPERSPECTIVE_ENABLED");

        if (currentShadowmap)
            AerialPerspectiveRenderFeature.material.EnableKeyword("SHADOWMAP_ENABLED");
        else
            AerialPerspectiveRenderFeature.material.DisableKeyword("SHADOWMAP_ENABLED");

        cb.solar_irradiance = new Vector3(1.0f, 1.0f, 1.0f);
        cb.sun_angular_radius = sun_angular_radius;
        cb.absorption_extinction = new Vector3(0.000650f, 0.001881f, 0.000085f);
        const double max_sun_zenith_angle = Mathf.PI * 120.0 / 180.0;
        cb.mu_s_min = (float)Mathf.Cos((float)max_sun_zenith_angle);

        cb.rayleigh_density = new DensityProfileLayer(0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
            0.0f, 1.0f, -1.0f / EarthRayleighScaleHeight, 0.0f, 0.0f);
        cb.mie_density = new DensityProfileLayer(0.0f, 0.0f, 0.0f, 0.0f, 0.0f,
            0.0f, 1.0f, -1.0f / EarthMieScaleHeight, 0.0f, 0.0f);
        cb.absorption_density = new DensityProfileLayer(25.0f, 0.0f, 0.0f, 1.0f / 15.0f, -2.0f / 3.0f,
            0.0f, 0.0f, 0.0f, -1.0f / 15.0f, 8.0f / 3.0f);

        cb.mie_phase_function_g = mie_phase_function_g;
        cb.rayleigh_scattering = new Vector3(0.005802f, 0.013558f, 0.033100f);
        cb.rayleigh_scattering *= RayleighScatScale;
        cb.mie_scattering = new Vector3(0.003996f, 0.003996f, 0.003996f);
        cb.mie_extinction = new Vector3(0.004440f, 0.004440f, 0.004440f);
        cb.mie_absorption = MaxZero3(sub3(cb.mie_extinction, cb.mie_scattering));
        cb.ground_albedo = new Vector3(0.1f, 0.1f, 0.1f);
        cb.bottom_radius = EarthBottomRadius;
        cb.top_radius = EarthTopRadius;
        cb.MultipleScatteringFactor = currentMultipleScatteringFactor;
        cb.MultiScatteringLUTRes = MultiScatteringLUTRes;

        cb.TRANSMITTANCE_TEXTURE_WIDTH = LookUpTablesInfo.TRANSMITTANCE_TEXTURE_WIDTH;
        cb.TRANSMITTANCE_TEXTURE_HEIGHT = LookUpTablesInfo.TRANSMITTANCE_TEXTURE_HEIGHT;
        cb.IRRADIANCE_TEXTURE_WIDTH = LookUpTablesInfo.IRRADIANCE_TEXTURE_WIDTH;
        cb.IRRADIANCE_TEXTURE_HEIGHT = LookUpTablesInfo.IRRADIANCE_TEXTURE_HEIGHT;
        cb.SCATTERING_TEXTURE_R_SIZE = LookUpTablesInfo.SCATTERING_TEXTURE_R_SIZE;
        cb.SCATTERING_TEXTURE_MU_SIZE = LookUpTablesInfo.SCATTERING_TEXTURE_MU_SIZE;
        cb.SCATTERING_TEXTURE_MU_S_SIZE = LookUpTablesInfo.SCATTERING_TEXTURE_MU_S_SIZE;
        cb.SCATTERING_TEXTURE_NU_SIZE = LookUpTablesInfo.SCATTERING_TEXTURE_NU_SIZE;
        cb.SKY_SPECTRAL_RADIANCE_TO_LUMINANCE = new Vector3(114974.916437f, 71305.954816f, 65310.548555f);
        cb.SUN_SPECTRAL_RADIANCE_TO_LUMINANCE = new Vector3(98242.786222f, 69954.398112f, 66475.012354f);

        //深度值，渲染到纹理。Y要翻转
        var projectionMatrix = GL.GetGPUProjectionMatrix(camera.projectionMatrix, true);
        Matrix4x4 viewProjMat = projectionMatrix * camera.worldToCameraMatrix;


        cb.gSkyViewProjMat = viewProjMat;
        cb.gSkyInvViewProjMat = viewProjMat.inverse;
        // var a2=cb.gSkyInvViewProjMat.MultiplyPoint(new Vector3(-1, 1, -1));
        // var a3=GL.GetGPUProjectionMatrix(camera.projectionMatrix, false).MultiplyPoint(new Vector3(0, 0, 1));
        cb.gSkyInvProjMat = projectionMatrix.inverse;
        cb.gSkyInvViewMat = camera.worldToCameraMatrix.inverse;
        cb.gShadowmapViewProjMat = viewProjMat;
        cb.camera = camera.transform.position * scale;
        cb.view_ray = -camera.transform.forward;
        cb.sun_direction = -mainLight.transform.forward;

        mConstantBufferCPU.gViewProjMat = viewProjMat;
        mConstantBufferCPU.gColor = new Vector4(0.0f, 1.0f, 1.0f, 1.0f);
        mConstantBufferCPU.gResolution = new Vector3(Screen.width, Screen.height);
        mConstantBufferCPU.gMouseLastDownPos = new float[2];
        mConstantBufferCPU.gSunIlluminance = Vector3.one * mSunIlluminanceScale;
        mConstantBufferCPU.gScreenshotCaptureActive = 0.5f;
        mConstantBufferCPU.gScatteringMaxPathDepth = NumScatteringOrder;
        uiViewRayMarchMaxSPP = uiViewRayMarchMinSPP >= uiViewRayMarchMaxSPP
            ? uiViewRayMarchMinSPP + 1
            : uiViewRayMarchMaxSPP;
        mConstantBufferCPU.RayMarchMinMaxSPP = new Vector3(uiViewRayMarchMinSPP, uiViewRayMarchMaxSPP);

        SetComputeShaderConstant(typeof(CommonConstantBufferStructure), mConstantBufferCPU);
        SetComputeShaderConstant(typeof(SkyAtmosphereConstantBufferStructure), cb);
    }

    int NumScatteringOrder = 4;
    int uiViewRayMarchMinSPP = 4;
    int uiViewRayMarchMaxSPP = 14;
    private RenderTexture _transmittanceLUT;
    private RenderTexture _newMuliScattLUT;
    private RenderTexture _skyViewLUT;
    private RenderTexture _cameraVolumeLUT;

    [FormerlySerializedAs("ScatteringComputeShader")]
    public ComputeShader computeShader;

    private void PrecomputeTransmittanceLUT()
    {
        Vector2Int size = new Vector2Int(LookUpTablesInfo.TRANSMITTANCE_TEXTURE_WIDTH,
            LookUpTablesInfo.TRANSMITTANCE_TEXTURE_HEIGHT);
        Common.CheckOrCreateLUT(ref _transmittanceLUT, size, RenderTextureFormat.ARGBHalf);
        int index = computeShader.FindKernel("IntergalTransmittanceLUT");
        computeShader.SetTexture(index, Shader.PropertyToID("_TransmittanceLUT"), _transmittanceLUT);
        Common.Dispatch(computeShader, index, size);
    }

    private void PrecomputeMuliScattLUT()
    {
        Vector2Int size = new Vector2Int(LookUpTablesInfo.SCATTERING_TEXTURE_R_SIZE,
            LookUpTablesInfo.SCATTERING_TEXTURE_R_SIZE);
        Common.CheckOrCreateLUT(ref _newMuliScattLUT, size, RenderTextureFormat.ARGBHalf);
        int index = computeShader.FindKernel("NewMultiScattCS");
        computeShader.SetTexture(index, Shader.PropertyToID("TransmittanceLutTexture"), _transmittanceLUT);
        computeShader.SetTexture(index, Shader.PropertyToID("OutputTexture"), _newMuliScattLUT);
        Common.Dispatch(computeShader, index, size);
    }

    private void PrecomputeSkyViewLUT()
    {
        Vector2Int size = new Vector2Int(192, 108);
        Common.CheckOrCreateLUT(ref _skyViewLUT, size, RenderTextureFormat.RGB111110Float);
        int index = computeShader.FindKernel("IntergalSkyViewLutPS");
        computeShader.SetTexture(index, Shader.PropertyToID("TransmittanceLutTexture"), _transmittanceLUT);
        computeShader.SetTexture(index, Shader.PropertyToID("MultiScatTexture"), _newMuliScattLUT);
        computeShader.SetTexture(index, Shader.PropertyToID("_SkyViewLUT"), _skyViewLUT);
        Common.Dispatch(computeShader, index, size);
    }

    void PrecomputeCameraVolumeWithRayMarch()
    {
        Vector2Int size = Vector2Int.one * 64;
        Common.CheckOrCreateLUT(ref _cameraVolumeLUT, size, RenderTextureFormat.ARGBHalf, size.x);
        int index = computeShader.FindKernel("IntergalCameraVolumeLUT");
        computeShader.SetTexture(index, Shader.PropertyToID("TransmittanceLutTexture"), _transmittanceLUT);
        computeShader.SetTexture(index, Shader.PropertyToID("MultiScatTexture"), _newMuliScattLUT);
        computeShader.SetTexture(index, Shader.PropertyToID("_CameraVolumeLUT"), _cameraVolumeLUT);
        Common.Dispatch(computeShader, index, size, size.x);
    }

    void RenderSky()
    {
        renderSkyMat.SetTexture(Shader.PropertyToID("SkyViewLutTexture"), _skyViewLUT);
        AerialPerspectiveRenderFeature.material.SetTexture(Shader.PropertyToID("TransmittanceLutTexture"),
            _transmittanceLUT);
        AerialPerspectiveRenderFeature.material.SetTexture(Shader.PropertyToID("MultiScatTexture"), _newMuliScattLUT);
        AerialPerspectiveRenderFeature.material.SetTexture(Shader.PropertyToID("AtmosphereCameraScatteringVolume"),
            _cameraVolumeLUT);
    }

    // Update is called once per frame
    void Update()
    {
        UpdateConstantBuff();
        PrecomputeTransmittanceLUT();
        if (currentMultiscatapprox)
        {
            computeShader.DisableKeyword("MULTISCATAPPROX_ENABLED");
            PrecomputeMuliScattLUT();
            computeShader.EnableKeyword("MULTISCATAPPROX_ENABLED");
        }
        else
        {
            computeShader.DisableKeyword("MULTISCATAPPROX_ENABLED");
        }

        PrecomputeSkyViewLUT();
        PrecomputeCameraVolumeWithRayMarch();
        RenderSky();
    }

    #region 常量缓冲区

    int SetComputeShaderConstant(Type structType, object cb)
    {
        FieldInfo[] fields = structType.GetFields(BindingFlags.Public | BindingFlags.Instance);
        int size = 0;
        foreach (FieldInfo field in fields)
        {
            var value = field.GetValue(cb);
            if (field.FieldType == typeof(float))
            {
                computeShader.SetFloat(field.Name, (float)value);
                renderSkyMat.SetFloat(field.Name, (float)value);
                AerialPerspectiveRenderFeature.material.SetFloat(field.Name, (float)value);
                size++;
            }
            else if (field.FieldType == typeof(int))
            {
                computeShader.SetInt(field.Name, (int)value);
                renderSkyMat.SetInt(field.Name, (int)value);
                AerialPerspectiveRenderFeature.material.SetInt(field.Name, (int)value);
                size++;
            }
            else if (field.FieldType == typeof(float[]))
            {
                computeShader.SetFloats(field.Name, (float[])value);
                renderSkyMat.SetFloatArray(field.Name, (float[])value);
                AerialPerspectiveRenderFeature.material.SetFloatArray(field.Name, (float[])value);
                size += ((float[])value).Length;
            }
            else if (field.FieldType == typeof(Vector3))
            {
                computeShader.SetVector(field.Name, (Vector3)value);
                renderSkyMat.SetVector(field.Name, (Vector3)value);
                AerialPerspectiveRenderFeature.material.SetVector(field.Name, (Vector3)value);
                size += 3;
            }
            else if (field.FieldType == typeof(Vector4))
            {
                computeShader.SetVector(field.Name, (Vector4)value);
                renderSkyMat.SetVector(field.Name, (Vector4)value);
                AerialPerspectiveRenderFeature.material.SetVector(field.Name, (Vector4)value);
                size += 4;
            }
            else if (field.FieldType == typeof(DensityProfileLayer))
            {
                computeShader.SetVectorArray(field.Name, ToVectorArray((DensityProfileLayer)value));
                renderSkyMat.SetVectorArray(field.Name, ToVectorArray((DensityProfileLayer)value));
                AerialPerspectiveRenderFeature.material.SetVectorArray(field.Name,
                    ToVectorArray((DensityProfileLayer)value));
                size += 10;
            }
            else if (field.FieldType == typeof(Matrix4x4))
            {
                computeShader.SetMatrix(field.Name, (Matrix4x4)value);
                renderSkyMat.SetMatrix(field.Name, (Matrix4x4)value);
                AerialPerspectiveRenderFeature.material.SetMatrix(field.Name, (Matrix4x4)value);
                size += 16;
            }
            else
            {
                throw new Exception("not find type:" + field.FieldType);
            }
        }

        return size;
    }

    struct CommonConstantBufferStructure
    {
        public Vector3 gResolution;
        public Matrix4x4 gViewProjMat;
        public Vector4 gColor;
        public Vector3 gSunIlluminance;
        public int gScatteringMaxPathDepth;
        public float[] gMouseLastDownPos;
        public float gScreenshotCaptureActive;
        public Vector3 RayMarchMinMaxSPP;
    };

    public struct DensityProfileLayer
    {
        public float width;
        public float exp_term;
        public float exp_scale;
        public float linear_term;
        public float constant_term;


        public float width2;
        public float exp_term2;
        public float exp_scale2;
        public float linear_term2;
        public float constant_term2;

        public DensityProfileLayer(float width, float exp_term, float exp_scale, float linear_term, float constant_term,
            float width2, float exp_term2, float exp_scale2, float linear_term2, float constant_term2)
        {
            this.width = width;
            this.exp_term = exp_term;
            this.exp_scale = exp_scale;
            this.linear_term = linear_term;
            this.constant_term = constant_term;

            this.width2 = width2;
            this.exp_term2 = exp_term2;
            this.exp_scale2 = exp_scale2;
            this.linear_term2 = linear_term2;
            this.constant_term2 = constant_term2;
        }
    }

    public struct SkyAtmosphereConstantBufferStructure
    {
        public Vector3 solar_irradiance;
        public float sun_angular_radius;

        public Vector3 absorption_extinction;
        public float mu_s_min;

        public Vector3 rayleigh_scattering;
        public float mie_phase_function_g;

        public Vector3 mie_scattering;
        public float bottom_radius;

        public Vector3 mie_extinction;
        public float top_radius;

        public Vector3 mie_absorption;
        public float pad00;

        public Vector3 ground_albedo;
        public float pad0;

        public DensityProfileLayer rayleigh_density;
        public DensityProfileLayer mie_density;
        public DensityProfileLayer absorption_density;

        public int TRANSMITTANCE_TEXTURE_WIDTH;
        public int TRANSMITTANCE_TEXTURE_HEIGHT;
        public int IRRADIANCE_TEXTURE_WIDTH;
        public int IRRADIANCE_TEXTURE_HEIGHT;

        public int SCATTERING_TEXTURE_R_SIZE;
        public int SCATTERING_TEXTURE_MU_SIZE;
        public int SCATTERING_TEXTURE_MU_S_SIZE;
        public int SCATTERING_TEXTURE_NU_SIZE;

        public Vector3 SKY_SPECTRAL_RADIANCE_TO_LUMINANCE;
        public float pad3;
        public Vector3 SUN_SPECTRAL_RADIANCE_TO_LUMINANCE;
        public float pad4;

        public Matrix4x4 gSkyViewProjMat;
        public Matrix4x4 gSkyInvViewProjMat;
        public Matrix4x4 gSkyInvProjMat;
        public Matrix4x4 gSkyInvViewMat;
        public Matrix4x4 gShadowmapViewProjMat;

        public Vector3 camera;
        public float pad5;
        public Vector3 sun_direction;
        public float pad6;
        public Vector3 view_ray;
        public float pad7;

        public float MultipleScatteringFactor;
        public float MultiScatteringLUTRes;
        public float pad9;
        public float pad10;
    };

    Vector3 MaxZero3(Vector3 a)
    {
        Vector3 r;
        r.x = a.x > 0.0f ? a.x : 0.0f;
        r.y = a.y > 0.0f ? a.y : 0.0f;
        r.z = a.z > 0.0f ? a.z : 0.0f;
        return r;
    }

    Vector3 sub3(Vector3 a, Vector3 b)
    {
        Vector3 r;
        r.x = a.x - b.x;
        r.y = a.y - b.y;
        r.z = a.z - b.z;
        return r;
    }

    Vector4[] ToVectorArray(DensityProfileLayer value)
    {
        var array = new Vector4[3];

        array[0] = new Vector4(value.width, value.exp_term, value.exp_scale, value.linear_term);
        array[1] = new Vector4(value.constant_term, value.width2, value.exp_term2, value.exp_scale2);
        array[2] = new Vector4(value.linear_term2, value.constant_term2, 0, 0);
        return array;
    }

    struct LookUpTablesInfo
    {
        public const int TRANSMITTANCE_TEXTURE_WIDTH = 256;
        public const int TRANSMITTANCE_TEXTURE_HEIGHT = 64;

        public const int SCATTERING_TEXTURE_R_SIZE = 32;
        public const int SCATTERING_TEXTURE_MU_SIZE = 128;
        public const int SCATTERING_TEXTURE_MU_S_SIZE = 32;
        public const int SCATTERING_TEXTURE_NU_SIZE = 8;

        public const int IRRADIANCE_TEXTURE_WIDTH = 64;
        public const int IRRADIANCE_TEXTURE_HEIGHT = 16;
    }

    #endregion
}