# uxconf
uxconf is a collection of tools that can be used to manage, track and deploy various configuration sets using a simple hierarchical key-value database (which doubles as a filesystem) which is accessed in an uniform way independently of the specific configuration interfaces.

# Design
uxconf was partially inspired by [rbarrois](https://github.com/rbarrois)'s [uconf](https://github.com/rbarrois/uconf). implements the hourglass model: it utilizes a couple of frontend utilities and APIs, mutiple handlers for the different configuration formats and APIs.
The frontend is designed just like git: multiple utilities which act independently of each other but serve a common purpose.
The format handlers can be wrappers around standard Perl modules or format specifications (the latter is only for config files).
The coniguration file specifies the formats/APIs used by configuration sets and the backend format(s) for each of them.
The actual configuration sets can be stored using various backend formats: a git repo (the default one), a FUSE filesystem, INI file(s) with sets as sections.

# Installation
TODO

# Configuration
TODO

# Usage
TODO
