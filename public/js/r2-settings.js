const form = document.getElementById('r2-settings');
const status = document.getElementById('r2-status');
let busy = false;
async function submit(action) {
    if (busy) return;
    busy = true;
    form.querySelectorAll('button').forEach(button => { button.disabled = true; });
    status.textContent = action === 'check' ? '正在检查连接…' : '正在保存…';
    try {
        const response = await fetch(new URL(action === 'check' ? 'r2/check' : 'r2', location.href), { method: 'POST', body: new FormData(form) });
        const result = await response.json();
        if (!response.ok || !result.success) throw new Error(result.message || '请求失败。');
        status.textContent = result.message;
        if (action === 'save') {
            for (const id of ['access_key', 'secret_key']) {
                const input = document.getElementById(id);
                if (input.value) input.placeholder = '已保存，留空保留';
                input.value = '';
            }
        }
    } catch (error) { status.textContent = error.message || '请求失败，请刷新页面重试。'; }
    finally { busy = false; form.querySelectorAll('button').forEach(button => { button.disabled = false; }); }
}
form.addEventListener('submit', event => { event.preventDefault(); submit('save'); });
document.getElementById('r2-check').addEventListener('click', () => submit('check'));
document.getElementById('r2-cors').value = JSON.stringify([{
    AllowedOrigins: [location.origin], AllowedMethods: ['PUT', 'GET', 'HEAD'],
    AllowedHeaders: ['content-type', 'range'], ExposeHeaders: ['ETag', 'Content-Range', 'Content-Length'], MaxAgeSeconds: 3600,
}], null, 2);
