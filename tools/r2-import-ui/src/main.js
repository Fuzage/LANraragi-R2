import { prepareFile, uploadPrepared, createResultZip, formatBytes, friendlyError } from './engine.js';
import './style.css';

const $ = (id) => document.getElementById(id);
let prepared = null;
let resultZip = null;
let busy = false;
$('source-file').addEventListener('change', () => {
  prepared = null; resultZip = null;
  const file = $('source-file').files[0];
  $('file-name').textContent = file ? `${file.name} · ${formatBytes(file.size)}` : '尚未选择文件';
  $('convert').disabled = !file;
  $('result-card').hidden = true; $('error-card').hidden = true;
  $('r2-status').replaceChildren();
});
function setBusy(value) {
  busy = value;
  for (const id of ['source-file', 'pdf-dpi', 'parallelism', 'category-id']) $(id).disabled = value;
  $('convert').disabled = value || !$('source-file').files.length;
  $('upload-r2').disabled = value || !prepared;
  $('convert').textContent = value ? '正在本机处理…' : '开始本机整理';
}
function reportProgress(info) {
  $('progress').max = info.total || 1;
  $('progress').value = info.done || 0;
  $('progress-count').textContent = info.total ? `${info.done} / ${info.total}` : '';
  $('status').textContent = info.detail;
  $('current-page').textContent = '';
}
$('convert').addEventListener('click', async () => {
  if (busy) return;
  const file = $('source-file').files[0];
  if (!file) return;
  setBusy(true); $('progress-card').hidden = false; $('result-card').hidden = true; $('error-card').hidden = true;
  try {
    prepared = await prepareFile(file, { dpi: Number($('pdf-dpi').value), parallelism: Number($('parallelism').value), onProgress: reportProgress });
    $('status').textContent = '正在打包本地下载结果';
    resultZip = await createResultZip(prepared);
    const rows = [ ['页数', prepared.pages.length], ['源文件', formatBytes(file.size)], ['页图总计', formatBytes(prepared.totalBytes)],
      ['本地 ZIP 结果', formatBytes(resultZip.size)], ['直传 R2 总量（页图）', formatBytes(prepared.totalBytes)], ['处理时间', `${prepared.elapsedSeconds.toFixed(1)} 秒`] ];
    $('summary').replaceChildren();
    for (const [label, value] of rows) for (const text of [label, String(value)]) {
      const span = document.createElement('span'); span.textContent = text; $('summary').append(span);
    }
    const preserved = prepared.manifest.pages.filter(p => p.byteExact).length;
    $('verification').textContent = `原始图片字节保留 ${preserved} 页；无损像素转换 ${prepared.pages.length - preserved} 页。`;
    $('page-list').replaceChildren();
    for (const page of prepared.manifest.pages) {
      const li = document.createElement('li');
      li.textContent = `${page.index}. ${page.name} — ${page.width} × ${page.height} px，${formatBytes(page.bytes)}，${page.contentType.replace('image/', '')}`;
      $('page-list').append(li);
    }
    $('progress-card').hidden = true; $('result-card').hidden = false;
  } catch (error) {
    prepared = null; $('error-message').textContent = friendlyError(error); $('error-card').hidden = false;
  } finally { setBusy(false); }
});
$('download').addEventListener('click', () => {
  if (!resultZip) return;
  const url = URL.createObjectURL(resultZip);
  const link = document.createElement('a'); link.href = url;
  link.download = `${prepared.manifest.sourceName.replace(/\.[^.]+$/, '').replace(/[\\/:*?"<>|]/g, '_')}-pages.zip`;
  document.body.append(link); link.click(); link.remove(); setTimeout(() => URL.revokeObjectURL(url), 60_000);
});
$('upload-r2').addEventListener('click', async () => {
  if (!prepared || busy) return;
  setBusy(true);
  try {
    const result = await uploadPrepared(prepared, { categoryId: $('category-id').value, onProgress(info) {
      $('r2-status').textContent = info.detail + (info.totalBytes ? ` · ${formatBytes(info.bytesSent)} / ${formatBytes(info.totalBytes)}` : '');
    } });
    $('r2-status').textContent = `上传成功：${prepared.pages.length} 页。 `;
    for (const [label, path] of [['打开阅读器', `/reader?id=${encodeURIComponent(result.archiveId)}`], ['编辑元数据 / 导入标签', `/edit?id=${encodeURIComponent(result.archiveId)}`]]) {
      const a = document.createElement('a'); a.href = path; a.textContent = label; a.target = '_blank'; a.rel = 'noopener';
      $('r2-status').append(a, document.createTextNode(' '));
    }
  } catch (error) { $('r2-status').textContent = friendlyError(error); }
  finally { setBusy(false); }
});
fetch('/api/categories').then(r => r.ok ? r.json() : Promise.reject(new Error('分类读取失败'))).then(categories => {
  for (const category of categories.filter(c => !c.search)) {
    const option = document.createElement('option'); option.value = category.id; option.textContent = category.name; $('category-id').append(option);
  }
}).catch(() => { $('r2-status').textContent = '暂时无法读取分类，请刷新页面重试。'; });
