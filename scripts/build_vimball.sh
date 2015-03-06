#!/bin/sh

set -e -x

[ -f 'vimjs.vim' ] || (echo 'Must be run from the top-level directory' 1>&2; exit 1)
[ -d 'slimit' ] || (echo 'Pull slimit from https://github.com/rojer/slimit.git into the local directory.' 1>&2; exit 1)

rm -rf build
mkdir build
rsync -a LICENSE vimjs.vim build/
rsync -a slimit/ build/slimit/
#cd build
vim -s scripts/vimball.vim
