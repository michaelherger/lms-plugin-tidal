package Plugins::TIDAL::ProtocolHandler;

use strict;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);
use Scalar::Util qw(blessed);
use MIME::Base64 qw(encode_base64 decode_base64);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::TIDAL::Plugin;
use Plugins::TIDAL::API;

use base qw(Slim::Player::Protocols::HTTPS);

my $prefs = preferences('plugin.tidal');
my $serverPrefs = preferences('server');
my $log = logger('plugin.tidal');
my $cache = Slim::Utils::Cache->new;

# https://tidal.com/browse/track/95570766
# https://tidal.com/browse/album/95570764
# https://tidal.com/browse/playlist/5a36919b-251c-4fa7-802c-b659aef04216
my $URL_REGEX = qr{^https://(?:\w+\.)?tidal.com/(?:browse/)?(track|playlist|album|artist|mix)/([a-z\d-]+)}i;
my $URI_REGEX = qr{^tidal://(playlist|album|artist|mix|):?([0-9a-z-]+)}i;
Slim::Player::ProtocolHandlers->registerURLHandler($URL_REGEX, __PACKAGE__);
Slim::Player::ProtocolHandlers->registerURLHandler($URI_REGEX, __PACKAGE__);

# many method do not need override like isRemote, shouldLoop ...
sub canSkip { 1 }	# where is this called?
sub canSeek { 1 }

sub getFormatForURL {
	my ($class, $url) = @_;
	return if $url =~ m{^tidal://.+:.+};
	return Plugins::TIDAL::API::getFormat();
}

sub formatOverride {
	my ($class, $song) = @_;
	my $format = $song->pluginData('format') || Plugins::TIDAL::API::getFormat;
	return $format =~ s/mp4/aac/r;
}

# some TIDAL streams are compressed in a way which causes stutter on ip3k based players
sub forceTranscode {
	my ($self, $client, $format) = @_;
	return $format eq 'flc' && $client->model =~ /squeezebox|boom|transporter|receiver/;
}

# To support remote streaming (synced players), we need to subclass Protocols::HTTP
sub new {
	my $class  = shift;
	my $args   = shift;

	my $client = $args->{client};

	my $song      = $args->{song};
	my $streamUrl = $song->streamUrl() || return;

	main::DEBUGLOG && $log->debug( 'Remote streaming TIDAL track: ' . $streamUrl );

	my $sock = $class->SUPER::new( {
		url     => $streamUrl,
		song    => $args->{song},
		client  => $client,
	} ) || return;

	return $sock;
}

# Avoid scanning
sub scanUrl {
	my ( $class, $url, $args ) = @_;
	$args->{cb}->( $args->{song}->currentTrack() );
}

# Source for AudioScrobbler
sub audioScrobblerSource {
	my ( $class, $client, $url ) = @_;

	# P = Chosen by the user
	return 'P';
}

sub explodePlaylist {
	my ( $class, $client, $url, $cb ) = @_;

	my ($type, $id) = $url =~ $URL_REGEX;

	if ( !($type && $id) ) {
		($type, $id) = $url =~ $URI_REGEX;
	}

	if ($id) {
		return $cb->( [ $url ] ) if !$type;

		return $cb->( [ "tidal://$id." . Plugins::TIDAL::API::getFormat() ] ) if $type eq 'track';

		my $method;
		my $params = { id => $id };

		if ($type eq 'playlist') {
			$method = \&Plugins::TIDAL::Plugin::getPlaylist;
			$params = { uuid => $id };
		}
		elsif ($type eq 'album') {
			$method = \&Plugins::TIDAL::Plugin::getAlbum;
		}
		elsif ($type eq 'artist') {
			$method = \&Plugins::TIDAL::Plugin::getArtistTopTracks;
		}
		elsif ($type eq 'mix') {
			$method = \&Plugins::TIDAL::Plugin::getMix;
		}

		$method->($client, $cb, {}, $params);
		main::INFOLOG && $log->is_info && $log->info("Getting $url: method: $method, id: $id");
	}
	else {
		$cb->([]);
	}
}

sub _gotTrackError {
	my ( $error, $errorCb ) = @_;
	main::DEBUGLOG && $log->debug("Error during getTrackInfo: $error");
	$errorCb->($error);
}

sub getNextTrack {
	my ( $class, $song, $successCb, $errorCb ) = @_;
	my $client = $song->master();
	my $url = $song->track()->url;

	# Get track URL for the next track
	my $trackId = _getId($url);

	if (!$trackId) {
		$log->error("can't get trackId");
		return;
	}


	Plugins::TIDAL::Plugin::getAPIHandler($client)->getTrackUrl(sub {
		my $response = shift;

		# no DASH or other for now
		if ($response->{manifestMimeType} !~ m|application/vnd.tidal.bt|) {
			return _gotTrackError("only plays streams $response->{manifestMimeType}", $errorCb);
		}

		my $manifest = eval { from_json(decode_base64($response->{manifest})) };
		return _gotTrackError($@, $errorCb) if $@;

		my $streamUrl = $manifest->{urls}[0];
		my ($format) = $manifest->{mimeType} =~ m|audio/(\w+)|;
		$format =~ s/flac/flc/;

		# this should not happen
		if ($format ne Plugins::TIDAL::API::getFormat) {
			$log->warn("did not get the expected format for $trackId ($format <> " . Plugins::TIDAL::API::getFormat() . ')');
			$song->pluginData(format => $format);
		}

		# main::INFOLOG && $log->info("got $format track at $streamUrl");
		$song->streamUrl($streamUrl);

		# now try to acquire the header for seeking and various details
		Slim::Utils::Scanner::Remote::parseRemoteHeader(
			$song->track, $streamUrl, $format,
			sub {
				# update what we got from parsing actual stream and update metadata
				$song->pluginData('bitrate', sprintf("%.0f" . Slim::Utils::Strings::string('KBPS'), $song->track->bitrate/1000));
				$client->currentPlaylistUpdateTime( Time::HiRes::time() );
				Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
				$successCb->();
			},
			sub {
				my ($self, $error) = @_;
				$log->warn( "could not find $format header $error" );
				$successCb->();
			}
		);
	}, $trackId,
	{
		audioquality => $prefs->get('quality'),
		playbackmode => 'STREAM',
		assetpresentation => 'FULL',
	});

	main::DEBUGLOG && $log->is_debug && $log->debug("Getting next track playback info for $url");
}

my @pendingMeta = ();

sub getMetadataFor {
	my ( $class, $client, $url ) = @_;
	return {} unless $url;

	my $trackId = _getId($url);
	my $meta = $cache->get( 'tidal_meta_' . ($trackId || '') );

	# if metadata is in cache, we just need to add bitrate
	if ($meta) {
		# TODO - remove if we decide to move to our own cache file which we can version
		$meta->{artist} = $meta->{artist}->{name} if ref $meta->{artist};

		my $song = $client->playingSong();
		if ($song && ($song->track->url eq $url || $song->currentTrack->url eq $url)) {
			$meta->{bitrate} = $song->pluginData('bitrate') || 'n/a';
		}
		return $meta;
	}

	my $now = time();

	# first cleanup old requests in case some got lost
	@pendingMeta = grep { $_->{time} + 60 > $now } @pendingMeta;

	# only proceed if our request is not pending and we have less than 10 in parallel
	if ( !(grep { $_->{id} == $trackId } @pendingMeta) && scalar(@pendingMeta) < 10 ) {

		push @pendingMeta, {
			id => $trackId,
			time => $now,
		};

		main::DEBUGLOG && $log->is_debug && $log->debug("adding metadata query for $trackId");

		Plugins::TIDAL::Plugin::getAPIHandler($client)->track(sub {
			my $meta = shift;
			@pendingMeta = grep { $_->{id} != $trackId } @pendingMeta;
			return unless $meta;

			main::DEBUGLOG && $log->is_debug && $log->debug("found metadata for $trackId", Data::Dump::dump($meta));
			return if @pendingMeta;

			# Update the playlist time so the web will refresh, etc
			$client->currentPlaylistUpdateTime( Time::HiRes::time() );
			Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );
		}, $trackId );
	}

	my $icon = $class->getIcon();

	return $meta || {
		bitrate   => 'N/A',
		type      => Plugins::TIDAL::API::getFormat(),
		icon      => $icon,
		cover     => $icon,
	};
}

sub getIcon {
	my ( $class, $url ) = @_;
	return Plugins::TIDAL::Plugin->_pluginDataFor('icon');
}

sub _getId {
	my ($id) = $_[0] =~ m|tidal://(\d+)|;
	return $id;
}

1;
