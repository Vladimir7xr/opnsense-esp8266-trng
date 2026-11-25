<?php

function esp_trng_services()
{
    $services = array();

    $services[] = array(
        'description' => gettext('ESP8266 Hardware TRNG'),
        'pidfile' => '/var/run/esp-trng-feeder.pid',
        'configd' => array(
            'restart' => array('esp_trng restart'),
            'start' => array('esp_trng start'),
            'stop' => array('esp_trng stop'),
        ),
        'name' => 'esp_trng',
    );

    return $services;
}