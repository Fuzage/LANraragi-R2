import JSZip from 'jszip';
import * as pdfjsLib from 'pdfjs-dist';
import pdfWorkerUrl from 'pdfjs-dist/build/pdf.worker.mjs?url';
pdfjsLib.GlobalWorkerOptions.workerSrc = `${pdfWorkerUrl}?v=3`;

export async function prepareFile(file, { dpi = 300, parallelism = 2, onProgress = () => {} } = {}) {
    const started = performance.now();
    parallelism = Math.max(1, Math.min(2, Number(parallelism) || 1));
    dpi = [300, 450, 600].includes(Number(dpi)) ? Number(dpi) : 300;
    onProgress({ stage: 'prepare', done: 0, total: 0, detail: '读取文件' });
    const pages = await loadPages(file, dpi);
    if (!pages.length) { pages.dispose?.(); throw new Error('没有找到 PDF 页面或 JPG/PNG/WebP 图片。'); }
    const manifest = {
      format: 'LANraragi original-format page import',
      version: 1,
      sourceName: file.name,
      sourceBytes: 0,
      convertedAt: new Date().toISOString(),
      pages: [],
    };
    let totalPageBytes = 0;
    const convertedPages = [];

    let encoderPool = null;
    let nextPageIndex = 0;
    let completedPages = 0;
    let prepareFailed = false;
    const activePages = new Set();
    const processPage = async (index) => {
      const page = pages[index];
      const label = `${index + 1}. ${page.name}`;
      activePages.add(label);
      updateProgress();
      await nextPaint();

      const processed = await page.getImage();
      let pageBlob = processed.blob;
      let contentType = processed.contentType;
      let width = processed.width;
      let height = processed.height;
      let conversionMethod = processed.method;
      let byteExact = Boolean(processed.byteExact);
      let pixelExact = Boolean(processed.pixelExact);

      if (processed.imageData) {
        width = processed.imageData.width;
        height = processed.imageData.height;
        if (processed.method === 'pdf-embedded-image') {
          pageBlob = await imageDataBlob(processed.imageData, 'image/png');
          contentType = 'image/png';
          conversionMethod = 'pdf-embedded-image-png';
          pixelExact = true;
        } else {
          encoderPool ??= new WebpEncoderPool(parallelism);
          const encoded = await encoderPool.encode(processed.imageData, page.name);
          pageBlob = new Blob([encoded], { type: 'image/webp' });
          contentType = 'image/webp';
          conversionMethod = 'pdf-page-render-webp';
          pixelExact = true;
        }
      }

      const outputName = `pages/${String(index + 1).padStart(5, '0')}.${extensionForMime(contentType)}`;
      convertedPages[index] = pageBlob;
      totalPageBytes += pageBlob.size;
      manifest.pages[index] = {
        index: index + 1,
        name: page.name,
        object: outputName,
        width,
        height,
        sourceBytes: page.sourceBytes ?? null,
        bytes: pageBlob.size,
        contentType,
        byteExact,
        pixelExact,
        conversionMethod,
      };

      page.dispose?.();
      completedPages += 1;
      activePages.delete(label);
      updateProgress();
    };
    const runWorker = async () => {
      while (!prepareFailed && nextPageIndex < pages.length) {
        const index = nextPageIndex++;
        try { await processPage(index); }
        catch (error) { prepareFailed = true; throw error; }
      }
    };
    try {
      await waitWorkers(Array.from({ length: Math.min(parallelism, pages.length) }, () => runWorker()));
    } finally {
      encoderPool?.close();
      await pages.dispose?.();
    }

    function updateProgress() {
      onProgress({ stage: 'prepare', done: completedPages, total: pages.length,
        detail: activePages.size ? `正在整理 ${[...activePages].join('；')}` : '页图整理完成' });
    }
    return { manifest, pages: convertedPages, totalBytes: totalPageBytes,
      elapsedSeconds: (performance.now() - started) / 1000 };
}

export async function createResultZip(prepared) {
    const zip = new JSZip();
    prepared.pages.forEach((blob, index) => zip.file(prepared.manifest.pages[index].object, blob, { compression: 'STORE' }));
    zip.file('manifest.json', JSON.stringify(prepared.manifest, null, 2));
    return zip.generateAsync({ type: 'blob', compression: 'STORE', mimeType: 'application/zip' });
}

export async function uploadPrepared(prepared, { categoryId = '', onProgress = () => {} } = {}) {
    const { pages, manifest, totalBytes } = prepared;
    const planResponse = await fetch('/api/r2/upload-plan', {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ mode: 'bundle', bytes: totalBytes }),
    });
    const plan = await readApiResponse(planResponse, '无法创建 R2 上传任务。');
    onProgress({ stage: 'thumbnails', done: 0, total: pages.length, detail: '生成封面和小缩略图' });
    let offset = 0;
    manifest.pages = manifest.pages.map((page, index) => {
      const indexed = { ...page, offset, bytes: pages[index].size };
      offset += pages[index].size;
      return indexed;
    });
    manifest.bundleKey = plan.key;
    const descriptor = await createDescriptorArchive(manifest, plan, pages);
    const bundle = new Blob(pages, { type: 'application/octet-stream' });
    onProgress({ stage: 'upload', done: 0, total: pages.length, bytesSent: 0, totalBytes,
      detail: `整本直传 R2：0 / ${pages.length} 页` });
    await uploadPageWithRetry({ index: '整本图包', url: plan.url, blob: bundle,
      contentType: 'application/octet-stream',
      onProgress: (bytes) => onProgress({ stage: 'upload', done: 0, total: pages.length,
        bytesSent: Math.min(bytes, totalBytes), totalBytes, detail: `整本图包直传 R2：${formatBytes(bytes)} / ${formatBytes(totalBytes)}` }),
      onRetry: (attempt) => onProgress({ stage: 'upload', done: 0, total: pages.length,
        bytesSent: 0, totalBytes, detail: `整本图包上传重试 (${attempt}/2)` }),
    });
    onProgress({ stage: 'finalize', done: pages.length, total: pages.length, detail: '整本图包已上传，正在校验并登记档案' });
    const form = new FormData();
    form.append('batchId', plan.batchId);
    form.append('manifest', JSON.stringify({ ...manifest, bundleBytes: totalBytes }));
    if (categoryId) form.append('categoryId', categoryId);
    form.append('stub', descriptor, `${safeBaseName(manifest.sourceName)}.cbz`);
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 600_000);
    try {
      const response = await fetch('/api/r2/finalize', { method: 'POST', body: form, signal: controller.signal });
      return await readApiResponse(response, '页图已上传，但 R2 校验或档案登记失败。');
    } catch (error) {
      if (error.name === 'AbortError') throw new Error('页图已上传，但校验超过 10 分钟；请检查书库或服务器日志。');
      throw error;
    } finally { clearTimeout(timeout); }
}

async function readApiResponse(response, fallback) {
    let data;
    try { data = await response.json(); } catch { throw new Error(`${fallback} HTTP ${response.status}，接口返回格式异常。`); }
    if (!response.ok || data.success === 0) throw new Error(data.error || fallback);
    return data;
}

async function waitWorkers(promises) {
    const results = await Promise.allSettled(promises);
    const failure = results.find(result => result.status === 'rejected');
    if (failure) throw failure.reason;
}

async function createDescriptorArchive(manifest, plan, convertedPages) {
  const descriptor = new JSZip();
  const r2Manifest = {
    schema: 'lanraragi-r2-reading/v1',
    state: 'ready',
    batchId: plan.batchId,
    bundleKey: plan.key,
    bundleBytes: manifest.pages.reduce((sum, page) => sum + page.bytes, 0),
    sourceName: manifest.sourceName,
    sourceBytes: 0,
    losslessPages: true,
    pages: manifest.pages.map((page, index) => ({
      index: index + 1,
      name: page.name,
      offset: page.offset,
      contentType: page.contentType,
      width: page.width,
      height: page.height,
      bytes: page.bytes,
    })),
  };
  descriptor.file('__r2_manifest.json', JSON.stringify(r2Manifest));
  for (let index = 0; index < convertedPages.length; index += 1) {
    const thumb = await makeThumbnail(convertedPages[index]);
    const name = `__r2_thumbs/${String(index + 1).padStart(6, '0')}.jpg`;
    descriptor.file(name, thumb, { compression: 'STORE' });
    if (index === 0) descriptor.file('000001.jpg', thumb, { compression: 'STORE' });
  }
  return descriptor.generateAsync({ type: 'blob', compression: 'STORE', mimeType: 'application/zip' });
}

async function makeThumbnail(blob) {
  const bitmap = await createImageBitmap(blob);
  const scale = Math.min(1, 480 / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement('canvas');
  canvas.width = Math.max(1, Math.round(bitmap.width * scale));
  canvas.height = Math.max(1, Math.round(bitmap.height * scale));
  const context = canvas.getContext('2d', { alpha: false });
  context.fillStyle = '#fff';
  context.fillRect(0, 0, canvas.width, canvas.height);
  context.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  const thumbnail = await new Promise((resolve, reject) => canvas.toBlob((result) => result ? resolve(result) : reject(new Error('页面缩略图生成失败。')), 'image/jpeg', 0.78));
  canvas.width = 0;
  canvas.height = 0;
  return thumbnail;
}

async function uploadPageWithRetry({ index, url, blob, contentType = 'image/webp', onProgress, onRetry }) {
  for (let attempt = 0; attempt < 3; attempt += 1) {
    try {
      await putPageWithProgress(url, blob, contentType, onProgress);
      return;
    } catch (error) {
      if (!error.retryable || attempt === 2) {
        const label = typeof index === 'number' ? `第 ${index + 1} 页` : index;
        throw new Error(`${label}上传失败：${error.message}`);
      }
      onRetry(attempt + 1);
      await new Promise((resolve) => setTimeout(resolve, 800 * (attempt + 1)));
    }
  }
}

function putPageWithProgress(url, blob, contentType, onProgress) {
  return new Promise((resolve, reject) => {
    const request = new XMLHttpRequest();
    request.open('PUT', url);
    request.setRequestHeader('Content-Type', contentType);
    request.timeout = 15 * 60 * 1000;
    request.upload.addEventListener('progress', (event) => {
      if (event.lengthComputable) onProgress(event.loaded);
    });
    request.addEventListener('load', () => {
      if (request.status >= 200 && request.status < 300) resolve();
      else {
        const error = new Error(`HTTP ${request.status}。请检查 R2 签名或 CORS 配置。`);
        error.retryable = request.status === 408 || request.status === 429 || request.status >= 500;
        reject(error);
      }
    });
    request.addEventListener('error', () => {
      const error = new Error('网络中断或浏览器拦截请求（Safari 常显示 Load failed）。请保持页面在前台并检查 Wi‑Fi。');
      error.retryable = true;
      reject(error);
    });
    request.addEventListener('timeout', () => reject(new Error('单页上传超过 15 分钟，已超时。')));
    request.send(blob);
  });
}

async function loadPages(file, dpi = 300) {
  const ext = file.name.split('.').pop()?.toLowerCase();
  if (ext === 'pdf' || file.type === 'application/pdf') return pdfPages(file, dpi);
  if (['zip', 'cbz'].includes(ext) || file.type === 'application/zip') return zipPages(file);
  if (['png', 'jpg', 'jpeg', 'webp'].includes(ext) || file.type.startsWith('image/')) {
    return [{
      name: file.name,
      sourceBytes: file.size,
      getImage: async () => imageBlobPage(file, file.name),
    }];
  }
  throw new Error('暂不支持此格式。请选择 PDF、ZIP/CBZ，或 PNG/JPEG/WebP 图片。');
}

async function pdfPages(file, dpi) {
  const pdfData = await file.arrayBuffer();
  const loadingTask = pdfjsLib.getDocument({ data: pdfData });
  const pdfDocument = await loadingTask.promise;
  const pages = [];
  let rawPdfDocumentPromise;
  const getEmbeddedJpeg = async (ref, width, height) => {
    try {
      rawPdfDocumentPromise ??= loadRawPdfDocument(file);
      const rawPdfDocument = await rawPdfDocumentPromise;
      return extractPdfJpeg(rawPdfDocument, ref, width, height);
    } catch {
      return null;
    }
  };
  pages.dispose = () => loadingTask.destroy();
  for (let pageNo = 1; pageNo <= pdfDocument.numPages; pageNo += 1) {
    pages.push({
      name: `${String(pageNo).padStart(5, '0')}.pdf-page`,
      kind: 'pdf',
      getImage: async () => {
        const page = await pdfDocument.getPage(pageNo);
        const embedded = await extractFullPageImage(page, getEmbeddedJpeg);
        if (embedded) {
          page.cleanup();
          return embedded;
        }

        const scale = dpi / 72;
        const viewport = page.getViewport({ scale });
        const canvas = globalThis.document.createElement('canvas');
        canvas.width = Math.ceil(viewport.width);
        canvas.height = Math.ceil(viewport.height);
        const context = canvas.getContext('2d', { willReadFrequently: true, alpha: false });
        await page.render({ canvasContext: context, viewport, background: 'rgb(255,255,255)' }).promise;
        const data = context.getImageData(0, 0, canvas.width, canvas.height);
        canvas.width = 0;
        canvas.height = 0;
        page.cleanup();
        return { imageData: data, method: 'pdf-page-render' };
      },
    });
  }
  return pages;
}

// Bypass full-page rendering only for a single image that exactly covers an
// unrotated page. Extract the original stream only when it is a standalone JPEG
// with a safe color space; other embedded image data becomes a lossless PNG.
async function extractFullPageImage(page, getEmbeddedJpeg) {
  const [x1, y1, x2, y2] = page.view;
  const pageWidth = x2 - x1;
  const pageHeight = y2 - y1;
  if (page.rotate !== 0 || x1 !== 0 || y1 !== 0 || pageWidth <= 0 || pageHeight <= 0) return null;

  const list = await page.getOperatorList();
  const { fnArray, argsArray } = list;
  const paintOps = [];
  for (let i = 0; i < fnArray.length; i += 1) {
    const fn = fnArray[i];
    if (fn === pdfjsLib.OPS.paintImageXObject) paintOps.push(i);
    else if (![pdfjsLib.OPS.save, pdfjsLib.OPS.restore, pdfjsLib.OPS.transform, pdfjsLib.OPS.dependency].includes(fn)) return null;
  }
  if (paintOps.length !== 1) return null;

  const paintIndex = paintOps[0];
  const [objectId, opWidth, opHeight] = argsArray[paintIndex] ?? [];
  if (Math.abs(opWidth - pageWidth) > 0.01 || Math.abs(opHeight - pageHeight) > 0.01) return null;
  const fullPageTransform = argsArray.some((args, i) => fnArray[i] === pdfjsLib.OPS.transform
    && args?.length === 6
    && Math.abs(args[0] - pageWidth) < 0.01
    && Math.abs(args[1]) < 0.01
    && Math.abs(args[2]) < 0.01
    && Math.abs(args[3] - pageHeight) < 0.01
    && Math.abs(args[4] - x1) < 0.01
    && Math.abs(args[5] - y1) < 0.01);
  if (!fullPageTransform || typeof objectId !== 'string') return null;

  const image = await getPdfObject(page.objs, objectId);
  if (!image?.bitmap || image.width !== opWidth || image.height !== opHeight
    || image.bitmap.width !== image.width || image.bitmap.height !== image.height) return null;

  if (image.ref) {
    const jpegBytes = await getEmbeddedJpeg(image.ref, image.width, image.height);
    if (jpegBytes) {
      return {
        blob: new Blob([jpegBytes], { type: 'image/jpeg' }),
        contentType: 'image/jpeg',
        width: image.width,
        height: image.height,
        method: 'pdf-embedded-jpeg',
        byteExact: true,
      };
    }
  }

  const canvas = document.createElement('canvas');
  canvas.width = image.width;
  canvas.height = image.height;
  const context = canvas.getContext('2d', { willReadFrequently: true, alpha: false });
  context.drawImage(image.bitmap, 0, 0);
  const data = context.getImageData(0, 0, canvas.width, canvas.height);
  canvas.width = 0;
  canvas.height = 0;
  return { imageData: data, method: 'pdf-embedded-image' };
}

async function loadRawPdfDocument(file) {
  pdfLibClasses ??= await import('pdf-lib');
  const bytes = await file.arrayBuffer();
  return pdfLibClasses.PDFDocument.load(bytes, { updateMetadata: false });
}

function extractPdfJpeg(pdfDocument, pdfJsRef, width, height) {
  const match = /^(\d+)R(\d*)$/.exec(String(pdfJsRef));
  if (!match) return null;
  const { PDFName, PDFNumber, PDFRawStream, PDFRef } = pdfLibClasses ?? {};
  if (!PDFName || !PDFNumber || !PDFRawStream || !PDFRef) return null;
  const ref = PDFRef.of(Number(match[1]), Number(match[2] || 0));
  const stream = pdfDocument.context.lookup(ref);
  if (!(stream instanceof PDFRawStream)) return null;
  const name = (key) => stream.dict.lookup(PDFName.of(key))?.toString();
  if (name('Subtype') !== '/Image' || name('Filter') !== '/DCTDecode') return null;
  if (!['/DeviceRGB', '/DeviceGray'].includes(name('ColorSpace'))) return null;
  if (stream.dict.has(PDFName.of('SMask')) || stream.dict.has(PDFName.of('Mask'))
    || stream.dict.has(PDFName.of('Decode'))) return null;
  const streamWidth = stream.dict.lookupMaybe(PDFName.of('Width'), PDFNumber)?.asNumber();
  const streamHeight = stream.dict.lookupMaybe(PDFName.of('Height'), PDFNumber)?.asNumber();
  if (streamWidth !== width || streamHeight !== height) return null;
  const bytes = stream.getContents();
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8
    || bytes[bytes.length - 2] !== 0xff || bytes[bytes.length - 1] !== 0xd9) return null;
  return bytes;
}

let pdfLibClasses;

function getPdfObject(objects, id) {
  try {
    return Promise.resolve(objects.get(id));
  } catch {
    return new Promise((resolve, reject) => {
      try { objects.get(id, resolve); } catch (error) { reject(error); }
    });
  }
}

async function zipPages(file) {
  const archive = await JSZip.loadAsync(file, { checkCRC32: false, createFolders: false });
  const entries = Object.values(archive.files)
    .filter((entry) => !entry.dir && /\.(png|jpe?g|webp)$/i.test(entry.name))
    .sort((a, b) => a.name.localeCompare(b.name, undefined, { numeric: true, sensitivity: 'base' }));
  return entries.map((entry) => ({
    name: entry.name,
    getImage: async () => imageBlobPage(await entry.async('blob'), entry.name),
    sourceBytes: entry._data?.uncompressedSize ?? null,
  }));
}

async function imageBlobPage(blob, name) {
  const contentType = await detectImageMimeType(blob, name);
  const bitmap = await createImageBitmap(blob);
  const result = {
    blob,
    contentType,
    width: bitmap.width,
    height: bitmap.height,
    method: 'original-image',
    byteExact: true,
  };
  bitmap.close();
  return result;
}

async function detectImageMimeType(blob, name) {
  const bytes = new Uint8Array(await blob.slice(0, 12).arrayBuffer());
  if (bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff) return 'image/jpeg';
  if (bytes.length >= 8 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) return 'image/png';
  if (bytes.length >= 12 && String.fromCharCode(...bytes.slice(0, 4)) === 'RIFF'
    && String.fromCharCode(...bytes.slice(8, 12)) === 'WEBP') return 'image/webp';
  return imageMimeType(name);
}

function imageMimeType(name) {
  const ext = name.split('.').pop()?.toLowerCase();
  if (ext === 'png') return 'image/png';
  if (ext === 'webp') return 'image/webp';
  return 'image/jpeg';
}

function extensionForMime(contentType) {
  return ({ 'image/jpeg': 'jpg', 'image/png': 'png', 'image/webp': 'webp' })[contentType] || 'bin';
}

function mimeLabel(contentType) {
  return ({ 'image/jpeg': 'JPEG', 'image/png': 'PNG', 'image/webp': 'WebP' })[contentType] || contentType;
}

function imageDataBlob(imageData, contentType) {
  const canvas = document.createElement('canvas');
  canvas.width = imageData.width;
  canvas.height = imageData.height;
  canvas.getContext('2d').putImageData(imageData, 0, 0);
  return new Promise((resolve, reject) => {
    canvas.toBlob((blob) => {
      canvas.width = 0;
      canvas.height = 0;
      if (blob) resolve(blob);
      else reject(new Error('无法无损保存 PDF 内嵌图片。'));
    }, contentType);
  });
}

async function imageBlobData(blob) {
  const bitmap = await createImageBitmap(blob);
  const canvas = document.createElement('canvas');
  canvas.width = bitmap.width;
  canvas.height = bitmap.height;
  const context = canvas.getContext('2d', { willReadFrequently: true });
  context.drawImage(bitmap, 0, 0);
  const data = context.getImageData(0, 0, bitmap.width, bitmap.height);
  bitmap.close();
  canvas.width = 0;
  canvas.height = 0;
  return data;
}

class WebpEncoderPool {
  constructor(size) {
    this.queue = [];
    this.jobs = new Map();
    this.nextId = 1;
    this.workers = Array.from({ length: size }, () => {
      const worker = new Worker(new URL('../webp-worker.js', import.meta.url), { type: 'module' });
      const slot = { worker, jobId: null };
      worker.addEventListener('message', ({ data }) => {
        const job = this.jobs.get(data.id);
        this.jobs.delete(data.id);
        slot.jobId = null;
        if (data.error) job?.reject(new Error(data.error));
        else job?.resolve(data.encoded);
        this.dispatch();
      });
      worker.addEventListener('error', (event) => {
        const job = this.jobs.get(slot.jobId);
        this.jobs.delete(slot.jobId);
        slot.jobId = null;
        job?.reject(new Error(event.message || 'WebP 编码线程启动失败。'));
        this.dispatch();
      });
      return slot;
    });
  }

  encode(imageData, name) {
    return new Promise((resolve, reject) => {
      this.queue.push({ imageData, name, resolve, reject });
      this.dispatch();
    });
  }

  dispatch() {
    for (const slot of this.workers) {
      if (slot.jobId !== null || !this.queue.length) continue;
      const job = this.queue.shift();
      const id = this.nextId++;
      slot.jobId = id;
      this.jobs.set(id, job);
      const { data, width, height } = job.imageData;
      try {
        slot.worker.postMessage({ id, rgba: data.buffer, width, height, name: job.name }, [data.buffer]);
      } catch (error) {
        slot.jobId = null;
        this.jobs.delete(id);
        job.reject(error);
      }
    }
  }

  close() {
    for (const slot of this.workers) slot.worker.terminate();
    for (const job of this.jobs.values()) job.reject(new Error('WebP 编码任务已终止。'));
    for (const job of this.queue) job.reject(new Error('WebP 编码任务已终止。'));
    this.jobs.clear();
    this.queue.length = 0;
  }
}

function nextPaint() { return new Promise((resolve) => requestAnimationFrame(() => setTimeout(resolve, 0))); }
export function formatBytes(value) {
  if (value == null) return '—';
  if (value < 1024) return `${value} B`;
  const units = ['KB', 'MB', 'GB'];
  let amount = value / 1024;
  let unit = units[0];
  for (let i = 1; amount >= 1024 && i < units.length; i += 1) { amount /= 1024; unit = units[i]; }
  return `${amount.toFixed(2)} ${unit}`;
}
function safeBaseName(name) { return name.replace(/\.[^.]+$/, '').replace(/[\\/:*?"<>|]/g, '_').slice(0, 100) || 'pages'; }
function escapeText(value) { const element = document.createElement('span'); element.textContent = value; return element.innerHTML; }
export function friendlyError(error) {
  const message = error instanceof Error ? error.message : String(error);
  if (/password/i.test(message)) return 'PDF 有密码保护或无法读取。请先在设备上解除密码后再试。';
  if (/memory|allocation|out of/i.test(message)) return '手机可用内存不足。请选更小的文件，或把 PDF 页面最长边调低后重试。';
  return message;
}
