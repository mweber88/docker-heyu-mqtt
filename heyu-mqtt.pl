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
    $message = encode('UTF-8', $message, Encode::FB_CROAK);
    AE::log info => "topic = $topic";
    AE::log info => "message = $message";
    $topic =~ m{\Q$config->{mqtt_prefix}\E/([A-Z]\d+)/set};
    my $decoded_message = decode_json $message;
    AE::log info => "decoded message = Dumper($message)";
    for my $key (keys %$decoded_message) {
        AE::log info => "key $key is %$decoded_message{$key}\n";  
    }
    
    my $device = $1;
    AE::log info => "device = $device";
    if ($message =~ m{^on$|^off$}i) {
        AE::log info => "switching device $device $message";
        system($config->{heyu_cmd}, lc $message, $device);
    }
}

sub send_mqtt_status {
    my ($device, $status) = @_;
    $mqtt->publish(topic => "$config->{mqtt_prefix}/$device", message => sprintf('{"state":"%s"}', $status ? 'ON' : 'OFF'), retain => scalar($device =~ $config->{mqtt_retain_re}));
}

my $addr_queue = {};
sub process_heyu_line {
    my ($handle, $line) = @_;
    if ($line =~ m{Monitor started}) {
        AE::log note => "watching heyu monitor";
    } elsif ($line =~ m{  \S+ addr unit\s+\d+ : hu ([A-Z])(\d+)}) {
        my ($house, $unit) = ($1, $2);
        $addr_queue->{$house} ||= {};
        $addr_queue->{$house}{$unit} = 1;
    } elsif ($line =~ m{  \S+ func\s+(\w+) : hc ([A-Z])}) {
        my ($cmd, $house) = ($1, $2);
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
        send_mqtt_status($device, 1);
    } elsif ($cmd eq 'off') {
        send_mqtt_status($device, 0);
    }
}

$mqtt->subscribe(topic => "$config->{mqtt_prefix}/+/set", callback => \&receive_mqtt_set)->cb(sub {
    AE::log note => "subscribed to MQTT topic $config->{mqtt_prefix}/+/set";
});

my $monitor = AnyEvent::Run->new(
    cmd => [ $config->{heyu_cmd}, 'monitor' ],
    on_read => sub {
        my $handle = shift;
        $handle->push_read( line => \&process_heyu_line );
    },
    on_error => sub {
        my ($handle, $fatal, $msg) = @_;
        AE::log error => "error running heyu monitor: $msg";
    },
);

AnyEvent->condvar->recv;
