using UnityEngine;
using UnityEngine.Rendering;

public static class Common
{
    public static void CheckOrCreateLUT(ref RenderTexture targetLUT, Vector2Int size, RenderTextureFormat format,
        int depth = 0)
    {
        if (targetLUT == null || (targetLUT.width != size.x || targetLUT.height != size.y))
        {
            if (targetLUT != null) targetLUT.Release();

            var rt = new RenderTexture(size.x, size.y, 0,
                format, RenderTextureReadWrite.Linear);
            if (depth > 0)
            {
                rt.dimension = TextureDimension.Tex3D;
                rt.volumeDepth = depth;
            }

            rt.useMipMap = false;
            rt.filterMode = FilterMode.Bilinear;
            rt.enableRandomWrite = true;
            rt.Create();
            targetLUT = rt;
        }
    }

    public static void Dispatch(ComputeShader cs, int kernel, Vector2Int lutSize, int z = 1)
    {
        cs.GetKernelThreadGroupSizes(kernel, out var threadNumX, out var threadNumY, out var threadNumZ);
        cs.Dispatch(kernel, lutSize.x / (int)threadNumX,
            lutSize.y / (int)threadNumY, z);
    }
}