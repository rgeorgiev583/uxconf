#!/usr/bin/env perl -w

use strict;
use warnings;

use v5.012;

use Config::Augeas;
use Fuse;
use POSIX;
use Fcntl ':mode';
use Parse::Path;

my $RETAIN_BRACKETS;
my $VALIDATE_PATH_PREFIX;

my $MODE;
my $UID;
my $GID;
my $ATIME;
my $MTIME;
my $CTIME;

my $aug;

my @groups;

my $last_ino;
my %inos;

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
    return '' if $path =~ /[\[\]*]/;

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

sub exists_xpath
{
    my $xpath = shift;
    return 1 if $xpath eq '/';
    return 0 if $xpath eq '';
    my $exists = scalar $aug->match($xpath);
    $inos{$xpath} = ++$last_ino if $exists && not defined $inos{$xpath};
    return $exists;
}

sub isdir_xpath
{
    my $xpath = shift;
    return scalar $aug->match("$xpath/*") || not defined $aug->get($xpath);
}

sub validate_xpath_prefix
{
    my $xpath = shift;
    return -ENOENT if $xpath eq '';
    my $hpath = Parse::Path->new(path => $xpath, style => 'File::Unix', auto_cleanup => 1);
    $hpath->pop;

    while ($hpath->depth)
    {
        return -ENOENT  unless exists_xpath($hpath->as_string);
        return -ENOTDIR unless  isdir_xpath($hpath->as_string);
        $hpath->pop;
    }

    return 0;
}

sub validate_xpath
{
    my $xpath = shift;

    if ($VALIDATE_PATH_PREFIX)
    {
        my $errcode = validate_xpath_prefix($xpath);
        return $errcode if $errcode;
    }

    return -ENOENT unless exists_xpath($xpath);
    return 0;
}

sub aug_getattr
{
    my $path = shift;
    my $xpath = fspath2xpath($path);
    my $errcode = validate_xpath($xpath);
    return $errcode if $errcode;
    my $ino  = defined $inos{$xpath} ? $inos{$xpath} : 0;
    my $isdir = isdir_xpath($xpath) && $path !~ /(?<=\/)[value]$/;
    my $mode = $isdir ? $MODE | S_IFDIR : $MODE | S_IFREG;
    my $len = $isdir ? 4096 : length $aug->get($xpath);

    #
    # The list returned contains the following fields:
    #   ($dev, $ino, $mode, $nlink, $uid, $gid, $rdev, $size, $atime, $mtime, $ctime, $blksize, $blocks),
    # the meanings of which are as follows:
    #
    #  0 dev      device number of filesystem
    #  1 ino      inode number
    #  2 mode     file mode  (type and permissions)
    #  3 nlink    number of (hard) links to the file
    #  4 uid      numeric user ID of file's owner
    #  5 gid      numeric group ID of file's owner
    #  6 rdev     the device identifier (special files only)
    #  7 size     total size of file, in bytes
    #  8 atime    last access time in seconds since the epoch
    #  9 mtime    last modify time in seconds since the epoch
    # 10 ctime    inode change time (NOT creation time!) in seconds since the epoch
    # 11 blksize  preferred block size for file system I/O
    # 12 blocks   actual number of blocks allocated
    #
    return (40, $ino, $mode, 1, $UID, $GID, 0, $len, $ATIME, $MTIME, $CTIME, 1024, 1);
}

sub aug_getdir
{
    my $dirname = shift;
    my $xdirname = fspath2xpath($dirname);
    my $errcode = validate_xpath($xdirname);
    return $errcode if $errcode;
    return -ENOTDIR if not isdir_xpath($xdirname) || $dirname =~ /(?<=\/)[value]$/;
    my @list = map xpath2fspath $aug->match("$xdirname/*");
    unshift @list, '[value]' if defined $aug->get($xdirname);
    return (@list, 0);
}

sub aug_mkdir
{
    my $dirname = shift;
    my $xdirname = fspath2xpath($dirname);
    my $errcode;
    $errcode = validate_xpath_prefix($xdirname) if $VALIDATE_PATH_PREFIX;
    return $errcode if $errcode;
    return defined $aug->get($xdirname) ? -EEXIST : -EPERM if $dirname =~ /(?<=\/)[value]$/;
    return -EEXIST if exists_xpath($xdirname);
    my $success = $aug->srun("touch $xdirname");
    $inos{$xdirname} = ++$last_ino if $success && not defined $inos{$xdirname};
    return -EPERM if $aug->error eq 'pathx';
    return -ENOSPC if $aug->error eq 'nomem';
    return $success ? 0 : 1;
}

sub aug_unlink
{
    my $path = shift;
    my $xpath = fspath2xpath($path);
    my $errcode = validate_xpath($xpath);
    return $errcode if $errcode;
    return -EISDIR if isdir_xpath($xpath) && $path !~ /(?<=\/)[value]$/;
    my $success = $aug->srun("clear $xpath");
    return -EPERM if $aug->error eq 'pathx';
    return -EIO if $aug->error eq 'internal';
    return $success ? 0 : 1;
}

sub aug_rmdir
{
    my $dirname = shift;
    my $xdirname = fspath2xpath($dirname);
    return -ENOENT unless exists_xpath($xdirname);
    return -ENOTEMPTY if scalar $aug->match("$xdirname/*");
    return -ENOTDIR if defined $aug->get($xdirname);
    my $success = $aug->remove($xdirname);
    rebuild_inode_cache();
    return -EPERM if $aug->error eq 'pathx';
    return -ENOENT if $aug->error eq 'nomatch';
    return $success ? 0 : 1;
}

sub aug_rename
{
    my ($path, $newpath) = @_;
    my $xpath = fspath2xpath($path);
    return -ENOENT unless exists_xpath($xpath);
    my $isdir = isdir_xpath($xpath);
    my $xnewpath = fspath2xpath($newpath);
    return -ENOENT unless exists_xpath($xnewpath);
    my $isnewdir = isdir_xpath($xnewpath);
    return -EISDIR if $isnewdir && not $isdir;
    my $success = $aug->move($xpath, $isnewdir ? $xnewpath . '/' . $xpath : $xnewpath);
    rebuild_inode_cache();
    return -EPERM if $aug->error eq 'pathx';
    return -ENOSPC if $aug->error eq 'nomem';
    return -ENOENT if $aug->error eq 'nomatch';
    return -EINVAL if $aug->error_message eq "Cannot move node into its descendant";
    $inos{$xnewpath} = ++$last_ino if $success && not defined $inos{$xpath};
    return $success ? 0 : 1;
}

sub aug_truncate
{
    my ($path, $size) = @_;
    my $xpath = fspath2xpath($path);
    return -ENOENT unless exists_xpath($xpath);
    my $value = $aug->get($xpath);
    return -EISDIR if scalar $aug->match("$xpath/*") || not defined $value;
    my $len = length $value;
    return -EINVAL if $size < 0;
    return -EFBIG if $size > $len;
    return 0 if $size == $len;
    my $success = $aug->set($xpath, substr $value, 0, $size);
    rebuild_inode_cache();
    return -EPERM if $aug->error eq 'pathx';
    return -EIO if $aug->error eq 'internal';
    return $success ? 0 : 1;
}

sub aug_read
{
    my ($path, $size, $offset) = @_;
    my $xpath = fspath2xpath($path);
    return -ENOENT unless exists_xpath($xpath);
    my $value = $aug->get($xpath);
    return -EISDIR if scalar $aug->match("$xpath/*") || not defined $value;
    my $len = length $value;
    return -EINVAL if $offset < 0 || $size < 0 || $offset > $len;
    return 0 if $offset == $len || $size == 0;
    return substr $value, $offset, $size;
}

sub aug_write
{
    my ($path, $buffer, $offset) = @_;
    my $xpath = fspath2xpath($path);
    my $value = $aug->get($xpath);
    return -EISDIR if scalar $aug->match("$xpath/*") || not defined $value;
    my $len = length $value;
    return -EINVAL if $offset < 0;
    return -EFBIG if $offset > $len;
    my $size = length $buffer;
    return -EINVAL if $size < 0;
    return 0 if $size == 0;
    substr($value, $offset, $size) = $buffer;
    my $success = $aug->set($xpath, $value);
    rebuild_inode_cache();
    return -EPERM if $aug->error eq 'pathx';
    return -ENOSPC if $aug->error eq 'nomem';
    return -EIO if $aug->error eq 'internal';
    $inos{$xpath} = ++$last_ino if $success && not defined $inos{$xpath};
    return $success ? 0 : 1;
}

sub aug_flush
{
    my $path = shift;
    my $xpath = fspath2xpath($path);
    return -ENOENT unless exists_xpath($xpath);
    return -EISDIR if isdir_xpath($xpath);
    return $aug->save();
}

sub aug_create
{
    my $path = shift;
    my $xpath = fspath2xpath($path);
    return -EEXIST if scalar $aug->match($xpath);
    my $success = $aug->set($xpath, '');
    rebuild_inode_cache();
    return -EPERM if $aug->error eq 'pathx';
    return -ENOSPC if $aug->error eq 'nomem';
    $inos{$xpath} = ++$last_ino if $success && not defined $inos{$xpath};
    return $success ? 0 : 1;
}

my $aug_dir = shift @ARGV;
$aug = Config::Augeas->new(root => $aug_dir);

$RETAIN_BRACKETS = 1;

my @root_stat = stat $aug_dir;
$MODE = $root_stat[2];
$MODE &= ~S_IXUSR;
$MODE &= ~S_IXGRP;
$MODE &= ~S_IXOTH;
$UID = $root_stat[4];
$GID = $root_stat[5];
$ATIME = $root_stat[8];
$MTIME = $root_stat[9];
$CTIME = $root_stat[10];

$last_ino = 1;
$inos{'/'} = 1;

Fuse::main
(
    mountpoint => shift @ARGV,
    getattr    => \&aug_getattr,
    getdir     => \&aug_getdir,
    mkdir      => \&aug_mkdir,
    unlink     => \&aug_unlink,
    rmdir      => \&aug_rmdir,
    rename     => \&aug_rename,
    truncate   => \&aug_truncate,
    read       => \&aug_read,
    write      => \&aug_write,
    flush      => \&aug_flush,
    create     => \&aug_create,
);
