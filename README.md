# SBOZYP

sbozyp is a package manager for Slackware's [SlackBuilds.org](https://slackbuilds.org/).

I created sbozyp because I wanted to and do not claim that it is better, worse, or the same compared to its alternatives.

# USER MANUAL

The user manual can be viewed online [here](https://metacpan.org/release/NHUBBARD/App-sbozyp-0.0.5/view/bin/sbozyp), or after installation with `$ man sbozyp`.

# FEATURES

* Built in dependency resolution
* Multiple repository support
* Pure CLI user interface (no ncurses)
* Package browsing, searching, and querying
* Requires zero dependencies on a full Slackware install
* Supports Slackware 15.0 and greater

# INSTALLATION

```
# VERSION=0.0.5
# wget https://cpan.metacpan.org/authors/id/N/NH/NHUBBARD/App-sbozyp-$VERSION.tar.gz
# tar -xf App-sbozyp-$VERSION.tar.gz
# chmod +x App-sbozyp-$VERSION/package/sbozyp.SlackBuild
# App-sbozyp-$VERSION/package/sbozyp.SlackBuild
# upgradepkg --reinstall --install-new /tmp/sbozyp-$VERSION-noarch-1_nbh.tgz
```

If you are using slackpkg then you probably don't want it to manage sbozyp
```
# echo sbozyp >> /etc/slackpkg/blacklist
```

# DEVELOPERS

Do not hesitate to open an [issue](https://github.com/NicholasBHubbard/sbozyp/issues/new) or [pull request](https://github.com/NicholasBHubbard/sbozyp/compare)!

Run the test code:

```
$ cpanm --installdeps
$ perl t/sbozyp.t
```

New release:

* Update version in README.md, Changes, bin/sbozyp, and sbozyp.SlackBuild
* Update Changes file to reflect new changes
* Perform a CPAN release
