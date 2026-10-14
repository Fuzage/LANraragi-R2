import { prepareFile, uploadPrepared, formatBytes, friendlyError } from './engine.js';

const queue = [];
let activeJobs = 0;
let nextId = 0;
if (window.matchMedia('(pointer: coarse)').matches) {
  document.getElementById('r2-upload-concurrency').value = '1';
}
const notify = (task, info) => document.dispatchEvent(new CustomEvent('lrr:r2-status', { detail: { id: task.id, name: task.name, ...info } }));
function enqueue(files) {
  const categoryId = document.getElementById('category').value;
  const dpi = Number(document.getElementById('r2-dpi').value);
  const parallelism = Number(document.getElementById('r2-parallelism').value);
  for (const file of files) {
    const task = { id: `r2-${Date.now()}-${++nextId}`, file, name: file.name, categoryId, dpi, parallelism };
    queue.push(task);
    notify(task, { state: 'queued', detail: '等待上传到 R2', progress: 0 });
  }
  runQueue();
}
function runQueue() {
  const limit = Math.max(1, Number(document.getElementById('r2-upload-concurrency').value) || 1);
  while (activeJobs < limit && queue.length) {
    const task = queue.shift();
    activeJobs++;
    processTask(task).finally(() => {
      activeJobs--;
      runQueue();
    });
  }
}
async function processTask(task) {
  let prepared;
  try {
    prepared = await prepareFile(task.file, { dpi: task.dpi, parallelism: task.parallelism, onProgress(info) {
      notify(task, { state: 'processing', detail: info.detail, progress: info.total ? 40 * info.done / info.total : 0 });
    } });
    const result = await uploadPrepared(prepared, { categoryId: task.categoryId, onProgress(info) {
      let value = 40;
      if (info.stage === 'upload') value = 40 + 50 * (info.totalBytes ? info.bytesSent / info.totalBytes : info.done / info.total);
      if (info.stage === 'finalize') value = 95;
      notify(task, { state: 'processing', detail: info.detail + (info.totalBytes ? ` · ${formatBytes(info.bytesSent)} / ${formatBytes(info.totalBytes)}` : ''), progress: value });
    } });
    notify(task, { state: 'complete', progress: 100, archiveId: result.archiveId, title: result.title,
      detail: `${prepared.pages.length} 页 · ${formatBytes(prepared.totalBytes)} · 整理 ${prepared.elapsedSeconds.toFixed(1)} 秒`,
      pages: prepared.manifest.pages.map(({ index, name, width, height, bytes, contentType }) => ({ index, name, width, height, bytes, contentType })),
    });
  } catch (error) { notify(task, { state: 'failed', detail: friendlyError(error) }); }
  finally { prepared = null; task.file = null; }
}
const picker = document.getElementById('r2-fileupload');
picker.disabled = false;
document.getElementById('r2-loading').textContent = '';
picker.addEventListener('change', () => { enqueue(Array.from(picker.files)); picker.value = ''; });
document.addEventListener('lrr:r2-files', event => enqueue(event.detail.files));
window.addEventListener('beforeunload', event => {
  if (activeJobs || queue.length) { event.preventDefault(); event.returnValue = ''; }
});
