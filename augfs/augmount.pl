#!/usr/bin/env perl

use strict;
use warnings;

use v5.012;

use Config::Augeas;
use Fuse;
use File::Basename;
use POSIX qw(EEXIST ENOENT EISDIR ENOTDIR ENOTEMPTY EINVAL EPERM ENOSPC EIO EFBIG);

my $RETAIN_BRACKETS;

my $aug;
my @groups;

sub xpath2fspath
{
    my $path = shift;
    
    if ($RETAIN_BRACKETS)
    {
        $path =~ s/\[(\d+)\]/\/\[$1\]/g;
    }
    else
    {
        my $match_group = qr/\[\d+\].*$/;

        while ($path =~ $match_group)
        {
            my $group = $path =~ s/$match_group//r;
            push @groups, $group unless grep { $_ eq $group } @groups;
            $path =~ s/\[(\d+)\]/\/$1/;
        }
    }

    return $path;
}

sub fspath2xpath
{
    my $path = shift;
    $path =~ s/(?<=\/)[value]$//;
    $path =~ s/\/\[(\d+)\](?:\/|$)/\[$1\]/g;
    return 0 if $path =~ /[\[\]*]/;

    unless ($RETAIN_BRACKETS)
    {
        my $match_group = qr/\/\d+(?:\/.*|$)/;
        my $subst_path = $path;

        while ($subst_path =~ $match_group)
        {
            my $group = $subst_path =~ s/$match_group//r;
            my $match_subst = qr/\/(\d+)(?=\/|$)/;
            $subst_path =~ s/(.*)$match_subst//;
            $path =~ s/$1$match_subst/\[$1\]/ if grep { $_ eq $group } @groups;
        }
    }

    return $path;
}

sub aug_getdir
{
    my $dirname = shift;
    return -ENOTDIR if $dirname =~ /(?<=\/)[value]$/;
    my $xdirname = fspath2xpath($dirname);
    return -ENOENT unless $xdirname or scalar $aug->match($xdirname);
    my $value = $aug->get($xdirname);
    my @list = $aug->match("$xdirname/*");
    return -ENOTDIR unless scalar @list or not defined $value;
    @list = map \&xpath2fspath @list;
    unshift @list, '[value]' if defined $value;
    return (@list, 0);
}

sub aug_mkdir
{
    my $dirname = shift;
    return -EPERM if $dirname =~ /(?<=\/)[value]$/;
    my $xdirname = fspath2xpath($dirname);
    return -ENOENT unless $xdirname;
    return -EEXIST if scalar $aug->match($xdirname);
    my $success = $aug->srun("set $xdirname");
    return -EPERM if $aug->error eq 'pathx';
    return -ENOSPC if $aug->error eq 'nomem';
    return $success ? 0 : 1;
}

sub aug_unlink
{
    my $path = shift;
    my $xpath = fspath2xpath($path);
    return -ENOENT unless $xpath or scalar $aug->match($xpath);
    return -EISDIR if scalar $aug->match("$xpath/*") or not defined $aug->get($xpath);
    my $success = $aug->srun("clear $xpath");
    return -EPERM if $aug->error eq 'pathx';
    return -EIO if $aug->error eq 'internal';
    return $success ? 0 : 1;
}

sub aug_rmdir
{
    my $dirname = shift;
    my $xdirname = fspath2xpath($dirname);
    return -ENOENT unless $xdirname or scalar $aug->match($xdirname);
    return -ENOTEMPTY if scalar $aug->match("$xdirname/*");
    return -ENOTDIR if defined $aug->get($xdirname);
    my $success = $aug->remove($xdirname);
    return -EPERM if $aug->error eq 'pathx';
    return -ENOENT if $aug->error eq 'nomatch';
    return $success ? 0 : 1;
}

sub aug_rename
{
    my ($path, $newpath) = @_;
    my $xpath = fspath2xpath($path);
    return -ENOENT unless $xpath or scalar $aug->match($xpath);
    my $isdir = scalar $aug->match("$xpath/*") or not defined $aug->get($xpath);
    my $xnewpath = fspath2xpath($newpath);
    return -ENOENT unless $xnewpath or scalar $aug->match($xnewpath);
    my $isnewdir = scalar $aug->match("$xnewpath/*") or not defined $aug->get($xnewpath);
    return -EISDIR if $isnewdir and not $isdir;
    my $success = $aug->move($xpath, $isnewdir ? $xnewpath . '/' . basename($xpath) : $xnewpath);
    return -EPERM if $aug->error eq 'pathx';
    return -ENOSPC if $aug->error eq 'nomem';
    return -ENOENT if $aug->error eq 'nomatch';
    return -EINVAL if $aug->error_message eq "Cannot move node into its descendant";
    return $success ? 0 : 1;
}

sub aug_truncate
{
    my ($path, $size) = @_;
    my $xpath = fspath2xpath($path);
    return -ENOENT unless $xpath or scalar $aug->match($xpath);
    my $value = $aug->get($xpath);
    return -EISDIR if scalar $aug->match("$xpath/*") or not defined $value;
    my $len = length $value;
    return -EINVAL if $size < 0;
    return -EFBIG if $size > $len;
    return 0 if $size == $len;
    my $success = $aug->set($xpath, substr $value, 0, $size);
    return -EPERM if $aug->error eq 'pathx';
    return -EIO if $aug->error eq 'internal';
    return $success ? 0 : 1;
}

sub aug_read
{
    my ($path, $size, $offset) = @_;
    my $xpath = fspath2xpath($path);
    return -ENOENT unless $xpath or scalar $aug->match($xpath);
    my $value = $aug->get($xpath);
    return -EISDIR if scalar $aug->match("$xpath/*") or not defined $value;
    my $len = length $value;
    return -EINVAL if $offset < 0 or $size < 0 or $offset > $len;
    return 0 if $offset == $len or $size == 0;
    return substr $value, $offset, $size;
}

sub aug_write
{
    my ($path, $buffer, $offset) = @_;
    my $xpath = fspath2xpath($path);
    my $value = $aug->get($xpath);
    return -EISDIR if scalar $aug->match("$xpath/*") or not defined $value;
    my $len = length $value;
    return -EINVAL if $offset < 0;
    return -EFBIG if $offset > $len;
    my $size = length $buffer;
    return -EINVAL if $size < 0;
    return 0 if $size == 0;
    substr($value, $offset, $size) = $buffer;
    my $success = $aug->set($xpath, $value);
    return -EPERM if $aug->error eq 'pathx';
    return -ENOSPC if $aug->error eq 'nomem';
    return -EIO if $aug->error eq 'internal';
    return $success ? 0 : 1;
}

sub aug_flush
{
    my $path = shift;
    my $xpath = fspath2xpath($path);
    return -ENOENT unless $xpath or scalar $aug->match($xpath);
    return -EISDIR if scalar $aug->match("$xpath/*") or not defined $aug->get($xpath);
    return $aug->save();
}

sub aug_create
{
    my $path = shift;
    my $xpath = fspath2xpath($path);
    return -EEXIST if scalar $aug->match($xpath);
    my $success = $aug->set($xpath, '');
    return -EPERM if $aug->error eq 'pathx';
    return -ENOSPC if $aug->error eq 'nomem';
    return $success ? 0 : 1;
}

$aug = Config::Augeas->new(root => shift @ARGV);
$RETAIN_BRACKETS = 1;

Fuse::main
(
    mountpoint => shift @ARGV,
    getdir => \&aug_getdir,
    truncate => \&aug_truncate,
    read => \&aug_read,
    write => \&aug_write,
    create => \&aug_create,
);
