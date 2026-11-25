<?php

namespace OPNsense\EspTrng\Api;

use OPNsense\Base\ApiControllerBase;

class ServiceController extends ApiControllerBase
{
    public function statsAction()
    {
        $statFile = '/tmp/esp_trng_stats.json';
        $pidFile = '/var/run/esp-trng-feeder.pid';
        $running = false;

        if (file_exists($pidFile)) {
            $pid = (int)trim((string)@file_get_contents($pidFile));
            if ($pid > 0) {
                $ret = 1;
                @exec('/bin/kill -0 ' . $pid . ' 2>/dev/null', $out, $ret);
                if ($ret === 0) {
                    $running = true;
                }
            }
        }

        $stats = [
            'status' => $running ? 'running' : 'stopped',
            'total_bytes' => 0,
            'speed_bps' => 0,
            'start_ts' => 0,
            'updated_ts' => 0,
        ];

        if ($running && file_exists($statFile)) {
            $raw = @file_get_contents($statFile);
            $decoded = json_decode((string)$raw, true);
            if (is_array($decoded)) {
                $stats = array_merge($stats, $decoded);
                if (time() - (int)$stats['updated_ts'] > 15) {
                    $stats['status'] = 'stalled';
                }
            }
        }

        $stats['device_present'] = file_exists('/dev/trng_esp');
        $stats['uptime_sec'] = ($running && $stats['start_ts'] > 0) ? max(0, time() - (int)$stats['start_ts']) : 0;

        if ($running && $stats['uptime_sec'] > 0 && $stats['total_bytes'] > 0) {
            $stats['speed_bps'] = round($stats['total_bytes'] / $stats['uptime_sec'], 2);
        }

        return $stats;
    }
}