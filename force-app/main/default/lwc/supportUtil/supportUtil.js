export const MAX_FILES = 5;
export const MAX_BYTES = 4 * 1024 * 1024;
export const ALLOWED_EXT = ['png', 'jpg', 'jpeg', 'pdf', 'txt', 'log', 'csv', 'json', 'xlsx', 'docx'];
export const ACCEPT = ALLOWED_EXT.map((e) => '.' + e).join(',');

export const CATEGORY_HINTS = {
    'Unlock Submitted Call': 'A submitted call has a mistake and you need to correct it.',
    'Unlock Monthly Plan': 'Your frozen monthly call plan needs to change.',
    'Data Correction': 'A doctor, hospital or account detail is wrong.',
    'Sync Problem': 'Data is not syncing, or something went missing.',
    'App Issue': 'The app crashed, froze or is showing something wrong.',
    'Access or Login': 'You cannot sign in or cannot see something you should.',
    'Samples or Inventory': 'A sample stock, lot or receipt problem.',
    'Expenses or Leave': 'A claim or leave request needs help.',
    'Territory or Alignment': 'Your territory or customer list looks wrong.',
    'How Do I': 'A question about how to do something.',
    'Other': 'Anything else.'
};

export function uuid() {
    if (typeof crypto !== 'undefined' && crypto.randomUUID) return crypto.randomUUID();
    return 'x' + Date.now().toString(36) + Math.random().toString(36).slice(2, 10);
}

export function errorText(e) {
    if (!e) return 'Something went wrong.';
    if (e.body) {
        if (typeof e.body.message === 'string') return e.body.message;
        if (Array.isArray(e.body) && e.body.length) return e.body.map((x) => x.message).join(' ');
        if (e.body.pageErrors && e.body.pageErrors.length) return e.body.pageErrors[0].message;
    }
    return e.message || 'Something went wrong.';
}

export function relTime(iso) {
    if (!iso) return '';
    const then = new Date(iso).getTime();
    const mins = Math.round((Date.now() - then) / 60000);
    if (mins < 1) return 'just now';
    if (mins < 60) return mins + ' min ago';
    const hrs = Math.round(mins / 60);
    if (hrs < 24) return hrs + ' h ago';
    const days = Math.round(hrs / 24);
    if (days < 8) return days + ' d ago';
    return new Date(iso).toLocaleDateString(undefined, { day: 'numeric', month: 'short' });
}

export function absTime(iso) {
    if (!iso) return '';
    return new Date(iso).toLocaleString(undefined, { day: 'numeric', month: 'short', hour: 'numeric', minute: '2-digit' });
}

export function slaText(row) {
    if (!row || !row.isOpen || !row.slaDueAt || row.awaiting !== 'Support') return { text: '', late: false };
    const mins = Math.round((new Date(row.slaDueAt).getTime() - Date.now()) / 60000);
    if (mins < 0) {
        const h = Math.round(-mins / 60);
        return { text: h < 1 ? 'Overdue' : 'Overdue ' + h + ' h', late: true };
    }
    if (mins < 60) return { text: mins + ' min left', late: false };
    const h = Math.round(mins / 60);
    return { text: h < 48 ? h + ' h left' : Math.round(h / 24) + ' d left', late: false };
}

export function statusClass(status) {
    const map = { New: 'pill pill-new', Open: 'pill pill-open', 'Waiting on Rep': 'pill pill-wait', Resolved: 'pill pill-done', Closed: 'pill pill-closed', Cancelled: 'pill pill-closed' };
    return map[status] || 'pill';
}

export function priorityClass(priority) {
    const map = { Urgent: 'pri pri-urgent', High: 'pri pri-high', Normal: 'pri pri-normal', Low: 'pri pri-low' };
    return map[priority] || 'pri';
}

export function fileExt(name) {
    const i = (name || '').lastIndexOf('.');
    return i < 0 ? '' : name.slice(i + 1).toLowerCase();
}

export function humanSize(bytes) {
    if (bytes == null) return '';
    if (bytes < 1024) return bytes + ' B';
    if (bytes < 1048576) return Math.round(bytes / 1024) + ' KB';
    return (bytes / 1048576).toFixed(1) + ' MB';
}

/** Reads a picked, dropped or pasted file. Rejects with a friendly message. */
export function readFile(file) {
    return new Promise((resolve, reject) => {
        let name = file.name || 'screenshot-' + new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-') + '.png';
        if (!fileExt(name)) name += '.png';
        const ext = fileExt(name);
        if (!ALLOWED_EXT.includes(ext)) {
            reject(new Error(name + ': this file type is not allowed. Use an image, PDF, text, CSV, Excel or Word file.'));
            return;
        }
        if (file.size > MAX_BYTES) {
            reject(new Error(name + ' is ' + humanSize(file.size) + '. Files added here can be up to 4 MB; shrink it, or add it in a reply from the iPad.'));
            return;
        }
        const reader = new FileReader();
        reader.onload = () => {
            const result = String(reader.result);
            resolve({
                key: uuid(),
                name,
                size: file.size,
                base64: result.substring(result.indexOf(',') + 1),
                previewUrl: ['png', 'jpg', 'jpeg'].includes(ext) ? result : null
            });
        };
        reader.onerror = () => reject(new Error('Could not read ' + name + '.'));
        reader.readAsDataURL(file);
    });
}