package Plugins::TIDAL::LastMix;

use strict;

use base qw(Plugins::LastMix::Services::Base);

use Slim::Utils::Log;

my $log = logger('plugin.tidal');

sub isEnabled {
	my ($class, $client) = @_;

	return unless $client;

	return unless Slim::Utils::PluginManager->isEnabled('Plugins::TIDAL::Plugin');

	require Plugins::TIDAL::API;
	return Plugins::TIDAL::API::->getSomeUserId() ? 'TIDAL' : undef;
}

sub lookup {
	my ($class, $client, $cb, $args) = @_;

	$class->client($client) if $client;
	$class->cb($cb) if $cb;
	$class->args($args) if $args;

	Plugins::TIDAL::Plugin::getAPIHandler($client)->search(sub {
		my $tracks = shift;

		if (!$tracks) {
			$class->cb->();
		}

		my $candidates = [];
		my $searchArtist = $class->args->{artist};
		my $ct = Plugins::TIDAL::API::getFormat();

		for my $track ( @$tracks ) {
			next unless $track->{artist} && $track->{id} && $track->{title} && $track->{artist}->{name};

			push @$candidates, {
				title  => $track->{title},
				artist => $track->{artist}->{name},
				url    => "tidal://$track->{id}.$ct",
			};
		}

		my $track = $class->extractTrack($candidates);

		main::INFOLOG && $log->is_info && $track && $log->info("Found $track for: $args->{title} - $args->{artist}");

		$class->cb->($track);
	}, {
		type => 'tracks',
		search => $args->{title},
		limit => 20,
	});
}

sub protocol { 'tidal' }

1;