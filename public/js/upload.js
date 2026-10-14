/**
 * Scripting for the Upload page
*/

import * as LRR from "./mod/common.js";
import * as Server from "./mod/server.js";
import I18N from "i18n";

let processingArchives = 0;
let completedArchives = 0;
let failedArchives = 0;
let totalUploads = 0;

// Set up jqueryfileupload.
export function initializeAll() {
    // bind events to DOM
    $(document).on("click.download-url", "#download-url", downloadUrl);
    $(document).on("click.return", "#return", () => { window.location.href = new LRR.ApiURL("/"); });
    initializeCategoryCreation();
    document.addEventListener('lrr:r2-status', updateR2Row);
    document.addEventListener('dragover', event => {
        if (Array.from(event.dataTransfer?.types || []).includes('Files')) event.preventDefault();
    });
    document.addEventListener('drop', event => {
        if (!event.dataTransfer?.files.length) return;
        event.preventDefault();
        const files = Array.from(event.dataTransfer.files);
        if (document.getElementById('drop-destination').value === 'vps') {
            $('#fileupload').fileupload('add', { files });
        } else if (!document.getElementById('r2-fileupload').disabled) {
            document.dispatchEvent(new CustomEvent('lrr:r2-files', { detail: { files } }));
        } else {
            LRR.showErrorToast('R2 导入器正在加载', new Error('请稍后再拖放文件。'));
        }
    });

    $("#fileupload").fileupload({
        dataType: "json",
        dropZone: null,
        pasteZone: null,
        formData() {
            const array = [{ name: "catid", value: document.getElementById("category").value }];
            return array;
        },
        done(e, data) {
            let result;
            if (data.result.success === 0) {
                result = `<tr><td>${LRR.encodeHTML(data.result.name)}</td>
                              <td><i class="fa fa-exclamation-circle" style="margin-left:20px; margin-right: 10px; color: red"></i>${LRR.encodeHTML(data.result.error)}</td>
                          </tr>`;
            } else {
                result = `<tr><td style="max-width:200px; overflow:hidden; text-overflow:ellipsis;">
                                <a href="#" id="${data.result.job}-name" title="${LRR.encodeHTML(data.result.name)}">${LRR.encodeHTML(data.result.name)}</a>
                              </td>
                              <td><i id="${data.result.job}-icon" class="fa fa-spinner fa-spin" style="margin-left:20px; margin-right: 10px;"></i>
                                <a href="#" id="${data.result.job}-link">${I18N.UploadProcessing(data.result.job)}</a>
                              </td>
                          </tr>`;
            }

            $("#progress .bar").css("width", "0%");
            $("#files").append(result);

            totalUploads += 1;
            if (data.result.success === 0) {
                failedArchives += 1;
                updateUploadCounters();
                return;
            }
            processingArchives += 1;
            updateUploadCounters();

            // Check minion job state periodically to update the result
            Server.checkJobStatus(
                data.result.job,
                true,
                (d) => handleCompletedUpload(data.result.job, d),
                (error) => handleFailedUpload(data.result.job, error),
            );
        },

        fail(e, data) {
            const result = `<tr><td>${LRR.encodeHTML(data.files?.[0]?.name || 'VPS 上传')}</td>
                              <td><i class="fa fa-exclamation-circle" style="margin-left:20px; margin-right: 10px; color: red"></i>${LRR.encodeHTML(data.errorThrown)}</td>
                          </tr>`;
            $("#progress .bar").css("width", "0%");
            $("#files").append(result);

            totalUploads += 1;
            failedArchives += 1;
            updateUploadCounters();
        },

        progressall(e, data) {
            const progress = parseInt((data.loaded / data.total) * 100, 10);
            $("#progress .bar").css("width", `${progress}%`);
        },

    });
}

const r2Rows = new Map();
function updateR2Row(event) {
    const data = event.detail;
    let row = r2Rows.get(data.id);
    if (!row) {
        const tr = document.createElement('tr'); tr.className = 'r2-upload-row';
        const nameCell = document.createElement('td');
        const badge = document.createElement('span'); badge.className = 'r2-upload-badge'; badge.textContent = 'R2';
        const name = document.createElement('span'); name.textContent = data.name;
        nameCell.append(badge, name);
        const resultCell = document.createElement('td');
        const status = document.createElement('div'); status.className = 'r2-upload-status';
        const progress = document.createElement('progress'); progress.max = 100; progress.value = 0;
        progress.setAttribute('aria-label', `${data.name} 上传进度`);
        resultCell.append(status, progress); tr.append(nameCell, resultCell);
        document.getElementById('files').append(tr);
        row = { nameCell, name, resultCell, status, progress, finished: false };
        r2Rows.set(data.id, row); totalUploads++; processingArchives++;
    }
    row.status.textContent = data.detail || '';
    if (Number.isFinite(data.progress)) row.progress.value = data.progress;
    if (!row.finished && (data.state === 'complete' || data.state === 'failed')) {
        row.finished = true; processingArchives--;
        row.progress.hidden = true;
        if (data.state === 'complete') {
            completedArchives++;
            const read = document.createElement('a'); read.href = new LRR.ApiURL(`/reader?id=${data.archiveId}`);
            read.textContent = data.title || data.name; read.target = '_blank'; read.rel = 'noopener';
            row.name.replaceWith(read);
            const edit = document.createElement('a'); edit.className = 'stdbtn r2-edit-metadata';
            edit.href = new LRR.ApiURL(`/edit?id=${data.archiveId}`); edit.target = '_blank'; edit.rel = 'noopener';
            edit.textContent = '编辑元数据'; row.resultCell.prepend(edit);
            const details = document.createElement('details'); details.className = 'r2-page-details';
            const summary = document.createElement('summary'); summary.textContent = '查看页图详情';
            const list = document.createElement('ol');
            for (const page of data.pages || []) {
                const li = document.createElement('li');
                li.textContent = `${page.index}. ${page.name} · ${page.width}×${page.height} · ${page.contentType.replace('image/', '')} · ${(page.bytes / 1024).toFixed(1)} KB`;
                list.append(li);
            }
            details.append(summary, list); row.resultCell.append(details);
        } else {
            failedArchives++; row.status.classList.add('r2-upload-error');
        }
    }
    updateUploadCounters();
}

function initializeCategoryCreation() {
    const panel = document.getElementById('new-category-form');
    const input = document.getElementById('new-category-name');
    const status = document.getElementById('new-category-status');
    document.getElementById('new-category-toggle').addEventListener('click', () => {
        panel.hidden = !panel.hidden;
        if (!panel.hidden) input.focus();
    });
    document.getElementById('new-category-cancel').addEventListener('click', () => { panel.hidden = true; });
    panel.addEventListener('submit', async event => {
        event.preventDefault();
        const name = input.value.trim();
        if (!name) { status.textContent = '请输入分类名称。'; input.focus(); return; }
        const save = document.getElementById('new-category-save'); save.disabled = true; status.textContent = '正在创建…';
        try {
            const query = new URLSearchParams({ name, search: '' });
            const response = await fetch(new LRR.ApiURL(`/api/categories?${query}`), { method: 'PUT' });
            const data = await response.json();
            if (!response.ok || !data.success) throw new Error(data.error || '分类创建失败。');
            const option = document.createElement('option'); option.value = data.category_id; option.textContent = name;
            document.getElementById('category').append(option); document.getElementById('category').value = data.category_id;
            panel.hidden = true; input.value = ''; status.textContent = '';
        } catch (error) { status.textContent = error.message; }
        finally { save.disabled = false; }
    });
}

// Handle updating the upload counters.
function updateUploadCounters() {
    $("#progressCount").html(`🤔 ${I18N.UploadResume1} : ${processingArchives} 🙌 ${I18N.UploadResume2} : ${completedArchives} 👹 ${I18N.UploadResume3} : ${failedArchives}`);

    let icon;
    if (completedArchives === totalUploads) {
        icon = "fas fa-check-circle";
    } else if (failedArchives > 0) {
        icon = "fas fa-exclamation-circle";
    } else {
        icon = "fa fa-spinner fa-spin";
    }
    $("#progressTotal").html(`<i class="${icon}"></i> ${I18N.UploadTotal}:${completedArchives + failedArchives}/${totalUploads}`);

    // At the end of the upload job, dump the search cache!
    if (processingArchives === 0) { Server.invalidateCache(); }
}

// Handle a completed job from minion.
// Update the line in upload results with the title, ID, message.
function handleCompletedUpload(jobID, d) {
    $(`#${jobID}-name`).text(d.result.title);

    if (d.result.id) {
        $(`#${jobID}-name`).attr("href", new LRR.ApiURL(`/reader?id=${d.result.id}`));
        $(`#${jobID}-link`).attr("href", new LRR.ApiURL(`/edit?id=${d.result.id}`));
        $(`#${jobID}-link`).attr("target", "_blank");
    }

    if (d.result.success) {
        $(`#${jobID}-link`).html(`${I18N.ClickToEdit}<br>(${LRR.encodeHTML(d.result.message)})`);
        $(`#${jobID}-icon`).attr("class", "fa fa-check-circle");
        completedArchives += 1;
    } else {
        $(`#${jobID}-link`).html(`${I18N.UploadError}<br>(${LRR.encodeHTML(d.result.message)})`);
        $(`#${jobID}-icon`).attr("class", "fa fa-exclamation-circle");
        failedArchives += 1;
    }

    processingArchives -= 1;
    updateUploadCounters();
}

function handleFailedUpload(jobID, d) {
    $(`#${jobID}-link`).html(`${I18N.UploadError}<br>(${LRR.encodeHTML(d)})`);
    $(`#${jobID}-icon`).attr("class", "fa fa-exclamation-circle");

    failedArchives += 1;
    processingArchives -= 1;
    updateUploadCounters();
}

// Send URLs to the Download API and add a Server.checkJobStatus to track its progress.
function downloadUrl() {
    const categoryID = document.getElementById("category").value;

    // One fetch job per non-empty line of the form
    $("#urlForm").val().split(/\r|\n/).forEach((url) => {
        if (url === "") return;

        const formData = new FormData();
        formData.append("url", url);

        if (categoryID !== "") {
            formData.append("catid", categoryID);
        }

        fetch(new LRR.ApiURL("/api/download_url"), {
            method: "POST",
            body: formData,
        })
            .then((response) => response.json())
            .then((data) => {
                if (data.success) {
                    const result = `<tr><td style="max-width:200px; overflow:hidden; text-overflow:ellipsis;">
                                    <a href="#" id="${data.job}-name" title="${LRR.encodeHTML(data.url)}">${LRR.encodeHTML(data.url)}</a>
                                </td>
                                <td><i id="${data.job}-icon" class="fa fa-spinner fa-spin" style="margin-left:20px; margin-right: 10px;"></i>
                                <a href="#" id="${data.job}-link">${I18N.DownloadProcessing(data.job)}</a>
                                </td>
                            </tr>`;

                    $("#files").append(result);

                    totalUploads += 1;
                    processingArchives += 1;
                    updateUploadCounters();

                    // Check minion job state periodically to update the result
                    Server.checkJobStatus(
                        data.job,
                        true,
                        (d) => handleCompletedUpload(data.job, d),
                        (error) => handleFailedUpload(data.job, error),
                    );
                } else {
                    throw new Error(data.message);
                }
            })
            .catch((error) => LRR.showErrorToast(I18N.DownloadError, error));
    });
}
