export default class EspTrng extends BaseTableWidget {
    constructor() {
        super();
        this.tickTimeout = 5;
    }

    getGridOptions() {
        return {
            sizeToContent: 250
        };
    }

    getMarkup() {
        let $container = $('<div></div>');
        let $table = this.createTable('esptrng-table', {
            headerPosition: 'left'
        });
        $container.append($table);
        return $container;
    }

    formatBytes(bytes) {
        if (!bytes || bytes <= 0) return '0 B';
        const units = ['B', 'KB', 'MB', 'GB'];
        const i = Math.min(Math.floor(Math.log(bytes) / Math.log(1024)), units.length - 1);
        return `${(bytes / Math.pow(1024, i)).toFixed(i === 0 ? 0 : 2)} ${units[i]}`;
    }

    formatUptime(sec) {
        if (!sec || sec <= 0) return '-';
        const d = Math.floor(sec / 86400);
        const h = Math.floor((sec % 86400) / 3600);
        const m = Math.floor((sec % 3600) / 60);
        const s = sec % 60;
        return (d > 0 ? `${d}d ` : '') + `${h}h ${m}m ${s}s`;
    }

    async onWidgetTick() {
        const data = await this.ajaxCall('/api/esptrng/service/stats');
        if (!data) return;

        let badgeClass = 'label-danger';
        let statusLabel = this.translations.stopped;

        if (data.status === 'running') {
            badgeClass = 'label-success';
            statusLabel = this.translations.running;
        } else if (data.status === 'stalled') {
            badgeClass = 'label-warning';
            statusLabel = this.translations.stalled;
        }

        const bps = data.speed_bps || 0;
        const bitsPerSec = (bps * 8).toFixed(1);

        const rows = [
            [
                this.translations.status,
                `<span class="label ${badgeClass}">${statusLabel}</span>`
            ],
            [
                this.translations.device,
                data.device_present ? '<span style="font-family: monospace;">/dev/trng_esp</span> (ESP8266)' : '<span class="text-danger">Disconnected</span>'
            ],
            [
                this.translations.injected,
                `<b>${this.formatBytes(data.total_bytes)}</b> (${data.total_bytes.toLocaleString()} B)`
            ],
            [
                this.translations.throughput,
                `${bps.toFixed(2)} B/s (${bitsPerSec} bit/s)`
            ],
            [
                this.translations.uptime,
                this.formatUptime(data.uptime_sec)
            ]
        ];

        this.updateTable('esptrng-table', rows);
    }
}