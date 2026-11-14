package Plugins::TIDAL::DontStopTheMusic;

use strict;

use List::Util qw(max);

use Slim::Plugin::DontStopTheMusic::Plugin;
use Slim::Utils::Log;

use Plugins::TIDAL::API;
use Plugins::TIDAL::ProtocolHandler;

use constant SEED_COUNT   => 5;     # number of tracks from the queue to seed from
use constant TARGET_COUNT => 25;    # number of tracks we try to return

# [ max. tracks per artist, don't play the same artist back to back ]
# Strictest rules first. We only relax them step by step if we'd end up with too few tracks.
my @PICK_PASSES = ( [1, 1], [2, 1], [2, 0], [4, 0] );

# words which mark another version of the same song: "(Remastered 2011)", "[Live]", " - Radio Edit"
my $VERSION_WORDS = qr/remaster(?:ed)?|live|version|edit|mono|stereo|acoustic|explicit/;
my $VERSION_IN_BRACKETS = qr/\s*[\(\[][^\)\]]*\b$VERSION_WORDS\b[^\)\]]*[\)\]]/;
# only strip the part after the dash if it's about the version: \"- 2011 Remaster\", \"- Live\", \"- Radio Edit\"
my $VERSION_AFTER_DASH = qr/\s+-\s+(?:[\w']+\s+){0,2}$VERSION_WORDS\b(?:\s+[\w']+){0,2}\s*$/;

my %STOP_WORDS = map { $_ => 1 } qw(and the feat ft);

my $log = logger('plugin.tidal');

sub init {
	Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_TIDAL_DSTM', \&dontStopTheMusic);
}

sub dontStopTheMusic {
	my ($client, $cb) = @_;

	my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, SEED_COUNT);

	# don't seed from radio stations - only do if we're playing from some track based source
	return $cb->($client) unless ref $seedTracks && @$seedTracks;

	# TIDAL tracks take precedence as seeds
	my (@seeds, @others, %seenSeed);
	foreach my $track (@$seedTracks) {
		my $id = Plugins::TIDAL::ProtocolHandler::getId($track->{extid} || '');

		if ($id) {
			push @seeds, { id => $id, artist => $track->{artist}, title => $track->{title} } unless $seenSeed{$id}++;
		}
		elsif ($track->{artist} && $track->{title}) {
			push @others, $track;
		}
	}

	my $api = Plugins::TIDAL::Plugin::getAPIHandler($client);
	return $cb->($client) unless $api;

	my $getRadios = sub {
		my ($seeds) = @_;

		return $cb->($client) unless $seeds && @$seeds;

		main::INFOLOG && $log->is_info && $log->info(sprintf('Auto-mixing TIDAL tracks from %s seed(s)', scalar @$seeds));

		my $pending = scalar @$seeds;
		my @results;

		for my $i ( 0 .. $#$seeds ) {
			$api->trackRadio(sub {
				$results[$i] = shift || [];

				return if --$pending;    # wait for the other requests

				my $urls = _mergeResults($seeds, \@results);

				main::INFOLOG && $log->is_info && $log->info(sprintf('Returning %s TIDAL tracks', scalar @$urls));

				$cb->($client, $urls);
			}, $seeds->[$i]->{id});
		}
	};

	return $getRadios->(\@seeds) if @seeds;

	# no TIDAL track in the queue: try to find the other tracks on TIDAL and seed from those
	return $cb->($client) unless @others;

	main::INFOLOG && $log->is_info && $log->info(sprintf('No TIDAL seeds - searching TIDAL for %s other track(s)', scalar @others));

	my $pending = scalar @others;
	my @found;

	for my $i ( 0 .. $#others ) {
		my $other = $others[$i];

		$api->search(sub {
			my $tracks = shift;

			$found[$i] = _findMatch($other, $tracks);

			return if --$pending;

			my %seen;
			my @matches = grep { $_ && !$seen{$_->{id}}++ } @found;

			$getRadios->(\@matches);
		}, {
			type   => 'tracks',
			search => join(' ', $other->{artist}, $other->{title}),
			limit  => 5,
		});
	}
}

# find the track in the search results which matches the artist and title we're looking for
sub _findMatch {
	my ($seed, $tracks) = @_;

	return unless ref $tracks eq 'ARRAY';

	my $title = _normalizeTitle($seed->{title});
	my %seedWords = map { $_ => 1 } _artistWords($seed->{artist});

	foreach my $track (@$tracks) {
		next unless $track->{id};
		next unless _normalizeTitle($track->{title}) eq $title;

		# artist names differ between sources ("Crosby & Nash" vs. "David Crosby, Graham Nash"): any shared word will do
		my @words = map { _artistWords($_->{name}) } grep { ref $_ } ($track->{artist}, @{ $track->{artists} || [] });
		next unless grep { $seedWords{$_} } @words;

		return { id => $track->{id}, artist => $seed->{artist}, title => $seed->{title} };
	}

	if (main::INFOLOG && $log->is_info) {
		$log->info(sprintf('No match on TIDAL for "%s - %s". Candidates: %s', $seed->{artist}, $seed->{title},
			join('; ', map { sprintf('%s - %s', _artistKey($_->{artist}), $_->{title} || '') } @$tracks)));
	}

	return;
}

sub _artistWords {
	my $name = lc(shift || '');
	return grep { length($_) > 1 && !$STOP_WORDS{$_} } split /[^\p{L}\p{N}]+/, $name;
}

# Merge the radios of the individual seeds:
# - interleave the lists so no single seed dominates
# - drop the seeds themselves and duplicates (same ID, or same artist + normalized title)
# - limit the number of tracks per artist, don't play the same artist back to back
sub _mergeResults {
	my ($seeds, $results) = @_;

	my (%seenId, %seenKey);
	$seenId{$_->{id}}++ foreach @$seeds;
	$seenKey{ _titleKey($_->{artist}, $_->{title}) }++ foreach grep { $_->{artist} && $_->{title} } @$seeds;

	# interleave
	my $most = max(map { scalar @$_ } @$results) || 0;
	my @candidates;

	for my $n ( 0 .. $most - 1 ) {
		foreach my $list (@$results) {
			my $track = $list->[$n] || next;
			next if !$track->{id} || $seenId{$track->{id}}++;
			next if $seenKey{ _titleKey($track->{artist}, $track->{title}) }++;

			push @candidates, {
				id     => $track->{id},
				artist => _artistKey($track->{artist}),
			};
		}
	}

	my (@picked, %perArtist);
	my $last = '';

	my $pick = sub {
		my ($maxPerArtist, $skipSameAsLast) = @_;

		foreach my $candidate (@candidates) {
			last if scalar @picked >= TARGET_COUNT;

			next if $candidate->{picked};
			next if ($perArtist{$candidate->{artist}} || 0) >= $maxPerArtist;
			next if $skipSameAsLast && $candidate->{artist} eq $last;

			push @picked, $candidate->{id};
			$candidate->{picked} = 1;
			$perArtist{$candidate->{artist}}++;
			$last = $candidate->{artist};
		}
	};

	$pick->(@$_) foreach @PICK_PASSES;

	my $format = Plugins::TIDAL::API::getFormat();
	return [ map { "tidal://$_.$format" } @picked ];
}

sub _artistKey {
	my $artist = shift;
	$artist = $artist->{name} || $artist->{id} if ref $artist;
	return lc($artist || '');
}

sub _titleKey {
	my ($artist, $title) = @_;
	return join('|', _artistKey($artist), _normalizeTitle($title));
}

# strip things like "(Remastered 2011)", "[Live]" or " - Radio Edit", so versions of the same song match
sub _normalizeTitle {
	my $title = lc(shift || '');

	$title =~ s/$VERSION_IN_BRACKETS//g;
	$title =~ s/$VERSION_AFTER_DASH//;
	$title =~ s/\s+/ /g;
	$title =~ s/^\s+|\s+$//g;

	return $title;
}

1;
