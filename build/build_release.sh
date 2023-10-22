#!/bin/bash

# error out if any statements fail
set -e
#set -x

tag='9.99.9'

function usage() {
  echo "$0 [options] <tag> <user> <email>"
  echo
  echo " tag :  Release tag (eg: 2.14.4, 2.15-beta1, ...)"
  echo " user:  Git username"
  echo " email: Git email"
  echo
  echo "Options:"
  echo " -h          : Print usage"
  echo " -b <branch> : Branch to release from (eg: trunk, 2.14.x, ...)"
  echo " -r <rev>    : Revision to release (eg: 12345)"
  echo " -g <ver>    : GeoTools version/revision (eg: 20.4, master:12345)"
  echo " -w <ver>    : GeoWebCache version/revision (eg: 1.14.4, 1.14.x:abcd)"
  echo
  echo "Environment variables:"
  echo " SKIP_BUILD : Skips main release build"
  echo " SKIP_COMMUNITY : Skips community release build"
  echo " SKIP_TAG : Skips tag on release branch"
  echo " SKIP_GT : Skips the GeoTools build, as used to build revision"
  echo " SKIP_GWC : Skips the GeoWebCache build, as used to build revision"
  echo " MAVEN_FLAGS : Used to supply additional option, like -U or -X to build process."
}

# parse options
while getopts "hb:r:g:w:" opt; do
  case $opt in
    h)
      usage
      exit
      ;;
    b)
      branch=$OPTARG
      ;;
    r)
      rev=$OPTARG
      ;;
    g)
      gt_ver=$OPTARG
      ;;
    w)
      gwc_ver=$OPTARG
      ;;
    \?)
      usage
      exit 1
      ;;
    :)
      echo "Option -$OPTARG requires an argument"
      exit 1
      ;;
  esac 
done

# load properties + functions
. "$( cd "$( dirname "$0" )" && pwd )"/properties
. "$( cd "$( dirname "$0" )" && pwd )"/functions

# move to root of source tree
pushd .. > /dev/null

dist=`pwd`/distribution/$tag
mkdir -p $dist/plugins

# setup geotools dependency
if [ -z $SKIP_GT ]; then
  if [ ! -z $gt_ver ]; then
    # deterine if this is a revision or version number 
    if [ "`is_version_num $gt_ver`" == "1" ]; then
       gt_tag=$gt_ver
    fi

    # if version specified as branch/revision check it out
    if [ -z $gt_tag ]; then
      arr=(${gt_ver//@/ }) 
      if [ "${#arr[@]}" != "2" ]; then
         echo "Bad version $gt_ver, must be specified as <branch>@<revision>"
         exit 1
      fi

      gt_branch=${arr[0]}
      gt_rev=${arr[1]}
      gt_dir=build/geotools/$gt_branch/$gt_rev
      if [ ! -e $gt_dir ]; then
         echo "cloning geotools repo from $GT_GIT_URL"
         git clone $GT_GIT_URL $gt_dir
      fi

      # checkout branch/rev
      pushd $gt_dir > /dev/null
      echo "checking out geotools ${gt_branch}@${gt_rev}"
      git checkout $gt_rev

      # build geotools
      mvn clean install $MAVEN_FLAGS -Dall -DskipTests
      popd > /dev/null

      # derive the gt version
      gt_tag=`get_pom_version $git_dir/pom.xml`
    fi
  fi
fi

if [ ! -z $gt_tag ]; then
  echo "GeoTools version = $gt_tag"
fi

# update geotools version
if [ ! -z $gt_tag ]; then
  sed -i "s/\(<gt.version>\).*\(<\/gt.version>\)/\1$gt_tag\2/g" src/pom.xml
else
  # look up from pom instead
  gt_tag=`cat src/pom.xml | grep "<gt.version>" | sed 's/ *<gt.version>\(.*\)<\/gt.version>/\1/g'`
fi

# setup geowebcache dependency
if [ -z $SKIP_GWC ]; then
  if [ ! -z $gwc_ver ]; then
    # deterine if this is a revision or version number 
    if [ "`is_version_num $gwc_ver`" == "1" ]; then
       gwc_tag=$gwc_ver
    fi

    # if version specified as branch/revision check it out
    if [ -z $gwc_tag ]; then
      arr=(${gwc_ver//@/ }) 
      if [ "${#arr[@]}" != "2" ]; then
         echo "Bad version $gwc_ver, must be specified as <branch>:<revision>"
         exit 1 
      fi

      gwc_branch=${arr[0]}
      gwc_rev=${arr[1]}
      gwc_dir=build/geowebcache/$gwc_branch/$gwc_rev
      if [ ! -e $gwc_dir -o ! -e $gwc_dir/geowebcache ]; then
         rm -rf $gwc_dir
         mkdir -p $gwc_dir 
         echo "checking out geowebache ${gwc_branch}@${gwc_rev}"
         git clone $GWC_GIT_URL $gwc_dir
         pushd $gwc_dir > /dev/null
         git checkout $gwc_rev
         popd > /dev/null
      fi

      # build geowebache
      pushd $gwc_dir/geowebcache > /dev/null
      mvn clean install $MAVEN_FLAGS -DskipTests

      # derive the gwc version
      gwc_tag=`get_pom_version pom.xml`

      popd > /dev/null
    fi
  fi
fi

if [ ! -z $gwc_tag ]; then
  echo "GeoWebCache version = $gwc_tag"
fi

# update geowebcache version
if [ ! -z $gwc_tag ]; then
  sed -i "s/\(<gwc.version>\).*\(<\/gwc.version>\)/\1$gwc_tag\2/g" src/pom.xml
else
  gwc_tag=`cat src/pom.xml | grep "<gwc.version>" | sed 's/ *<gwc.version>\(.*\)<\/gwc.version>/\1/g'`
fi

# update version numbers
old_ver=`get_pom_version src/pom.xml`

pushd src > /dev/null

# build the release
if [ -z $SKIP_BUILD ]; then
  echo "building release"
  mvn clean install $MAVEN_FLAGS -DskipTests -P release
else
   echo "Skipping mvn clean install $MAVEN_FLAGS -DskipTests -P release"
fi

echo "Skipping mvn clean install $MAVEN_FLAGS -P communityRelease -DskipTests"

echo "Assemble artifacts"
mvn assembly:single $MAVEN_FLAGS -N

artifacts=`pwd`/target/release
echo "artifacts = $artifacts"

# bundle up mac and windows installer stuff
pushd release/installer/mac > /dev/null
zip -q -r $artifacts/geoserver-$tag-mac.zip *
popd > /dev/null

pushd release/installer/win > /dev/null
zip -q -r $artifacts/geoserver-$tag-win.zip *
popd > /dev/null

# stage distribution artifacts
echo "copying artifacts to $dist"
cp $artifacts/*-plugin.zip $dist/plugins
for a in `ls $artifacts/*.zip | grep -v plugin`; do
  cp $a $dist
done

echo "generated artifacts:"
ls -la $dist

popd > /dev/null

echo "build complete, artifacts available at $DIST_URL/distribution/$tag"
exit 0
