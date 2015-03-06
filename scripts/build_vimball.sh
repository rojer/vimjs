#!/bin/sh

set -e -x

[ -f 'vimjs.vim' ] || (echo 'Must be run from the top-level directory' 1>&2; exit 1)
[ -d 'slimit' ] || (echo 'Pull slimit from https://github.com/rojer/slimit.git into the local directory.' 1>&2; exit 1)

rm -rf build
mkdir -p build/python2 build/ftplugin/js
cp vimjs.vim build/ftplugin/javascript_vimjs.vim
rsync -a slimit/src/slimit/ build/python2/slimit/
rsync -a slimit/CREDIT slimit/LICENSE slimit/README.rst build/python2/slimit/
vim -s scripts/vimball.vim
