package Plugins::TIDAL::API;

use strict;
use Exporter::Lite;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

our @EXPORT_OK = qw(AURL BURL KURL SCOPES GRANT_TYPE_DEVICE DEFAULT_LIMIT MAX_LIMIT PLAYLIST_LIMIT DEFAULT_TTL DYNAMIC_TTL USER_CONTENT_TTL);

use constant AURL => 'https://auth.tidal.com';
use constant BURL => 'https://api.tidal.com/v1';
use constant KURL => 'https://gist.githubusercontent.com/yaronzz/48d01f5a24b4b7b37f19443977c22cd6/raw/5a91ced856f06fe226c1c72996685463393a9d00/tidal-api-key.json';
use constant IURL => 'http://resources.tidal.com/images/';
use constant SCOPES => 'r_usr+w_usr';
use constant GRANT_TYPE_DEVICE => 'urn:ietf:params:oauth:grant-type:device_code';

use constant DEFAULT_LIMIT => 100;
use constant PLAYLIST_LIMIT => 50;
use constant MAX_LIMIT => 5000;

use constant DEFAULT_TTL => 86400;
use constant DYNAMIC_TTL => 3600;
use constant USER_CONTENT_TTL => 300;

use constant IMAGE_SIZES => {
	album  => '1280x1280',
	track  => '1280x1280',
	artist => '750x750',
	user   => '600x600',
	mood   => '684x684',
	genre  => '640x426',
	playlist => '1080x720',
	playlistSquare => '1080x1080',
};

use constant SOUND_QUALITY => {
	LOW => 'mp4',
	HIGH => 'mp4',
	LOSSLESS => 'flc',
	HI_RES => 'flc',
};

my $cache = Slim::Utils::Cache->new;
my $log = logger('plugin.tidal');
my $prefs = preferences('plugin.tidal');

sub getSomeUserId {
	my $accounts = $prefs->get('accounts');

	my ($account) = keys %$accounts;

	return $account;
}

sub getUserdata {
	my ($class, $userId) = @_;

	return unless $userId;

	my $accounts = $prefs->get('accounts') || return;

	return $accounts->{$userId};
}

sub getCountryCode {
	my ($class, $userId) = @_;
	my $userdata = $class->getUserdata($userId) || {};
	return $userdata->{countryCode} || 'US';
}

sub getFormat {
	return SOUND_QUALITY->{$prefs->get('quality')};
}

sub getImageUrl {
	my ($class, $data, $usePlaceholder, $type) = @_;

	if ( my $coverId = $data->{cover} || $data->{image} || $data->{squareImage} || $data->{picture} || ($data->{album} && $data->{album}->{cover}) ) {

		return $data->{cover} = $coverId if $coverId =~ /^https?:/;

		$type ||= $class->typeOfItem($data);
		my $iconSize;

		if ($type eq 'playlist' && $data->{squareImage}) {
			$coverId = $data->{squareImage};
			$iconSize ||= IMAGE_SIZES->{playlistSquare};
		}

		$iconSize ||= IMAGE_SIZES->{$type};

		if ($iconSize) {
			$coverId =~ s/-/\//g;
			$data->{cover} = IURL . $coverId . "/$iconSize.jpg";
		}
		else {
			delete $data->{cover};
		}
	}
	elsif (my $images = $data->{mixImages}) {
		my $image = $images->{L} || $images->{M} || $images->{S};
		$data->{cover} = $image->{url} if $image;
	}

	return $data->{cover} || (!main::SCANNER && $usePlaceholder && Plugins::TIDAL::Plugin->_pluginDataFor('icon'));
}

sub typeOfItem {
	my ($class, $item) = @_;

	if ( $item->{type} && $item->{type} =~ /(?:EXTURL|VIDEO)/ ) {}
	elsif ( defined $item->{hasPlaylists} && $item->{path} ) {
		return 'category';
	}
	elsif ( $item->{type} && $item->{type} =~ /(?:ALBUM|EP|SINGLE)/ ) {
		return 'album';
	}
	# playlist items can be of various types: USER, EDITORIAL etc., but they should have a numberOfTracks element
	elsif ( $item->{type} && defined $item->{numberOfTracks} && ($item->{created} || $item->{creator} || $item->{publicPlaylist} || $item->{lastUpdated}) ) {
		return 'playlist';
	}
	elsif ( defined $item->{mixNumber} && $item->{artists} ) {
		return 'mix'
	}
	# only artists have names? Others have titles?
	elsif ( $item->{name} ) {
		return 'artist';
	}
	# tracks?
	elsif ( !$item->{type} || defined $item->{duration}) {
		return 'track';
	}
	elsif ( main::INFOLOG ) {
		$log->warn('unknown tidal item type: ' . Data::Dump::dump($item));
		Slim::Utils::Log::logBacktrace('');
	}

	return '';
}

sub cacheTrackMetadata {
	my ($class, $tracks) = @_;

	return [] unless $tracks;

	return [ map {
		my $entry = $_;
		$entry = $entry->{item} if $entry->{item};

		my $oldMeta = $cache->get( 'tidal_meta_' . $entry->{id}) || {};
		my $icon = $class->getImageUrl($entry, 'usePlaceholder', 'track');

		# consolidate metadata in case parsing of stream came first (huh?)
		my $meta = {
			%$oldMeta,
			id => $entry->{id},
			title => $entry->{title},
			artist => $entry->{artist},
			artists => $entry->{artists},
			album => $entry->{album}->{title},
			album_id => $entry->{album}->{id},
			duration => $entry->{duration},
			icon => $icon,
			cover => $icon,
			replay_gain => $entry->{replayGain} || 0,
			peak => $entry->{peak},
			disc => $entry->{volumeNumber},
			tracknum => $entry->{trackNumber},
			url => $entry->{url},
		};

		# cache track metadata aggressively
		$cache->set( 'tidal_meta_' . $entry->{id}, $meta, time() + 90 * 86400);

		$meta;
	} @$tracks ];
}

sub getHumanReadableName {
	my ($class, $profile) = @_;
	return $profile->{nickname} || $profile->{firstName} || $profile->{fullName} || $profile->{username};
}

1;
