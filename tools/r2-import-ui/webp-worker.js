import { decode as decodeWebp, encode as encodeWebp } from '@jsquash/webp';

self.addEventListener('message', async ({ data }) => {
  const { id, rgba, width, height, name } = data;
  try {
    const imageData = { data: new Uint8ClampedArray(rgba), width, height };
    const encoded = await encodeWebp(imageData, {
      lossless: 1,
      quality: 50,
      method: 1,
      exact: 1,
      near_lossless: 100,
    });
    const decoded = await decodeWebp(encoded);
    assertSamePixels(imageData, decoded, name);
    self.postMessage({ id, encoded }, [encoded]);
  } catch (error) {
    self.postMessage({ id, error: error instanceof Error ? error.message : String(error) });
  }
});

function assertSamePixels(before, after, name) {
  if (before.width !== after.width || before.height !== after.height || before.data.length !== after.data.length) {
    throw new Error(`无损核对失败：${name} 的解码尺寸不一致。`);
  }
  for (let i = 0; i < before.data.length; i += 1) {
    if (before.data[i] !== after.data[i]) throw new Error(`无损核对失败：${name} 在像素字节 ${i} 处不一致。`);
  }
}
