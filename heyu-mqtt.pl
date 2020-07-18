#!/usr/bin/perl
use strict;

use AnyEvent::MQTT;
use AnyEvent::Run;
use JSON::PP;
use Data::Dumper;

my $config = {
    mqtt_host => $ENV{MQTT_HOST} || 'localhost',
    mqtt_port => $ENV{MQTT_PORT} || '1883',
    mqtt_user => $ENV{MQTT_USER},
    mqtt_password => $ENV{MQTT_PASSWORD},
    mqtt_prefix => $ENV{MQTT_PREFIX} || 'home/x10',
    mqtt_retain_re => qr/$ENV{MQTT_RETAIN_RE}/i || qr//, # retain everything
    heyu_cmd => $ENV{HEYU_CMD} || 'heyu',
};

my $mqtt = AnyEvent::MQTT->new(
    host => $config->{mqtt_host},
    port => $config->{mqtt_port},
    user_name => $config->{mqtt_user},
    password => $config->{mqtt_password},
);

sub receive_mqtt_set {
    #called when the subscribed topic is received 
    my ($topic, $message) = @_;
    #$message = encode('UTF-8', $message, Encode::FB_CROAK);
    #AE::log info => "message = $message";
    my $unjson = decode_json $message ;
    
    foreach my $jkey (keys %$unjson) {
        my $val = %$unjson{$jkey};
        AE::log info => "key is $jkey, value is $val\n"; 
    }

    $topic =~ m{\Q$config->{mqtt_prefix}\E/([a-z]+)/([A-Z]\d+)/set};

    my $device_type = $1;
    my $device = $2;
    my $testval = %$unjson{'state'};
    my $heyu_command_to_send = '';
    if ($device_type eq 'std') {
        #standard
        CORE::given($testval) {
            CORE::when('OFF') {
                $heyu_command_to_send = "off $device";
            }
            CORE::when('ON') {
                if (exists(%$unjson{'brightness'})) {
                    $heyu_command_to_send = "dimb $device %$unjson{'brightness'}";
                }
                else {
                    $heyu_command_to_send = "ON $device";
                }
            }
        }
    }
    elsif ($device_type eq 'ext') {
        #extended
        CORE::given($testval) {
            CORE::when('OFF') {
                $heyu_command_to_send = "xpreset $device 0";
            }
            CORE::when('ON') {
                if (exists(%$unjson{'brightness'})) {
                    $heyu_command_to_send = "xpreset $device %$unjson{'brightness'}";
                }
                else {
                    $heyu_command_to_send = "ON $device";
                }
            }
        }
    }

    if ($heyu_command_to_send ne '') {
        #here is where we switch depending on what we are doing
        AE::log info => "device = $device, device_type = $device_type, heyu_command_to_send = $heyu_command_to_send";
        AE::log info => "sending command  $heyu_command_to_send";
        system($config->{heyu_cmd}, lc $heyu_command_to_send);
    }
    
}

sub publish_mqtt_state {
    my ($device, $status) = @_;
    $mqtt->publish(topic => "$config->{mqtt_prefix}/$device", message => sprintf('{"state":"%s"}', $status ? 'ON' : 'OFF'), retain => scalar($device =~ $config->{mqtt_retain_re}));
}

my $addr_queue = {};
sub process_heyu_monitor_line {
    my ($handle, $line) = @_;
    if ($line =~ m{Monitor started}) {
        AE::log note => "watching heyu monitor";
    } elsif ($line =~ m{  \S+ addr unit\s+\d+ : hu ([A-Z])(\d+)}) {
        my ($house, $unit) = ($1, $2);
        $addr_queue->{$house} ||= {};
        $addr_queue->{$house}{$unit} = 1;
        AE::log info => "elsif 1 = " . Dumper($addr_queue);
    } elsif ($line =~ m{  \S+ func\s+(\w+) : hc ([A-Z])}) {
        my ($cmd, $house) = ($1, $2);
        AE::log info => "elsif 2 = " . Dumper($addr_queue);
        if ($addr_queue->{$house}) {
            for my $k (keys %{$addr_queue->{$house}}) {
                process_heyu_cmd(lc $cmd, "$house$k");
            }
            delete $addr_queue->{$house};
        }
    }
}

sub process_heyu_cmd {
    my ($cmd, $device) = @_;
    AE::log info => "processing $device: $cmd";
    if ($cmd eq 'on') {
        publish_mqtt_state($device, 1);
    } elsif ($cmd eq 'off') {
        publish_mqtt_state($device, 0);
    }
}

$mqtt->subscribe(topic => "$config->{mqtt_prefix}/+/+/set", callback => \&receive_mqtt_set)->cb(sub {
    AE::log note => "subscribed to MQTT topic $config->{mqtt_prefix}/+/+/set";
});

my $monitor = AnyEvent::Run->new(
    cmd => [ $config->{heyu_cmd}, 'monitor' ],
    on_read => sub {
        my $handle = shift;
        $handle->push_read( line => \&process_heyu_monitor_line );
    },
    on_error => sub {
        my ($handle, $fatal, $msg) = @_;
        AE::log error => "error running heyu monitor: $msg";
    },
);

AnyEvent->condvar->recv;
