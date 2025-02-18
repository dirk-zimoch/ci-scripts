# Utility functions for Travis scripts in ci-scripts
#
# This file is sourced by the executable scripts

# Portable version of 'sed -i'  (that MacOS doesn't provide)

# sedi (cmd, file)
# Do the equivalent of "sed -i cmd file"
sedi () {
  cat $2 | sed "$1" > $2.tmp$$; mv -f $2.tmp$$ $2
}

# Setup ANSI Colors
export ANSI_RED="\033[31;1m"
export ANSI_GREEN="\033[32;1m"
export ANSI_YELLOW="\033[33;1m"
export ANSI_BLUE="\033[34;1m"
export ANSI_RESET="\033[0m"
export ANSI_CLEAR="\033[0K"

# Travis log fold control
# from https://github.com/travis-ci/travis-rubies/blob/build/build.sh

fold_start() {
  echo -e "travis_fold:start:$1\\r${ANSI_YELLOW}$2${ANSI_RESET}"
}

fold_end() {
  echo -en "travis_fold:end:$1\\r"
}

# source_set(settings)
#
# Source a settings file (extension .set) found in the SETUP_DIRS path
# May be called recursively (from within a settings file)
declare -a SEEN_SETUPS
source_set() {
  local set_file=${1//[$'\r']}
  local set_dir
  local found=0
  if [ -z "${SETUP_DIRS}" ]
  then
    echo "${ANSI_RED}Search path for setup files (SETUP_PATH) is empty${ANSI_RESET}"
    [ "$UTILS_UNITTEST" ] || exit 1
  fi
  for set_dir in ${SETUP_DIRS}
  do
    if [ -e $set_dir/$set_file.set ]
    then
      if [[ " ${SEEN_SETUPS[@]} " =~ " $set_dir/$set_file.set " ]]
      then
        echo "Ignoring already included setup file $set_dir/$set_file.set"
        return
      fi
      SEEN_SETUPS+=($set_dir/$set_file.set)
      echo "Loading setup file $set_dir/$set_file.set"
      local line
      while read -r line
      do
        [ -z "$line" ] && continue
        echo $line | grep -q "^#" && continue
        if echo $line | grep -q "^include\W"
        then
          source_set $(echo $line | awk '{ print $2 }')
          continue
        fi
        if echo "$line" | grep -q "^\w\+="
        then
          IFS== read var value <<< "${line//[$'\r']}"
          value=$(sed "s/^\(\"\)\(.*\)\1\$/\2/g" <<< "$value") # remove surrounding quotes
          eval [ "\${$var}" ] || eval "$var=\$value"
        fi
      done < $set_dir/$set_file.set
      found=1
      break
    fi
  done
  if [ $found -eq 0 ]
  then
    echo "${ANSI_RED}Setup file $set_file.set does not exist in SETUP_DIRS search path ($SETUP_DIRS)${ANSI_RESET}"
    [ "$UTILS_UNITTEST" ] || exit 1
  fi
}

# update_release_local(varname, place)
#   varname   name of the variable to set in RELEASE.local
#   place     place (absolute path) of where variable should point to
#
# Manipulate RELEASE.local in the cache location:
# - replace "$varname=$place" line if it exists and has changed
# - otherwise add "$varname=$place" line and possibly move EPICS_BASE=... line to the end
update_release_local() {
  local var=$1
  local place=$2
  local release_local=${CACHEDIR}/RELEASE.local
  local updated_line="${var}=${place}"

  local ret=0
  [ -e ${release_local} ] && grep -q "${var}=" ${release_local} || ret=$?
  if [ $ret -eq 0 ]
  then
    existing_line=$(grep "${var}=" ${release_local})
    if [ "${existing_line}" != "${updated_line}" ]
    then
      sedi "s|${var}=.*|${var}=${place}|g" ${release_local}
    fi
  else
    echo "$var=$place" >> ${release_local}
    ret=0
    grep -q "EPICS_BASE=" ${release_local} || ret=$?
    if [ $ret -eq 0 ]
    then
      base_line=$(grep "EPICS_BASE=" ${release_local})
      sedi '\|EPICS_BASE=|d' ${release_local}
      echo ${base_line} >> ${release_local}
    fi
  fi
}

# add_dependency(dep, tag)
#
# Add a dependency to the cache area:
# - check out (recursive if configured) in the CACHE area unless it already exists and the
#   required commit has been built
# - Defaults:
#   $dep_DIRNAME = lower case ($dep)
#   $dep_REPONAME = lower case ($dep)
#   $dep_REPOURL = GitHub / $dep_REPOOWNER (or $REPOOWNER or epics-modules) / $dep_REPONAME .git
#   $dep_VARNAME = $dep
#   $dep_DEPTH = 5
#   $dep_RECURSIVE = 1/YES (0/NO to for a flat clone)
# - Add $dep_VARNAME line to the RELEASE.local file in the cache area (unless already there)
# - Add full path to $modules_to_compile
add_dependency() {
  curdir="$PWD"
  DEP=$1
  TAG=$2
  dep_lc=$(echo $DEP | tr 'A-Z' 'a-z')
  eval dirname=\${${DEP}_DIRNAME:=${dep_lc}}
  eval reponame=\${${DEP}_REPONAME:=${dep_lc}}
  eval repourl=\${${DEP}_REPOURL:="https://github.com/\${${DEP}_REPOOWNER:=${REPOOWNER:-epics-modules}}/${reponame}.git"}
  eval varname=\${${DEP}_VARNAME:=${DEP}}
  eval recursive=\${${DEP}_RECURSIVE:=1}
  recursive=$(echo $recursive | tr 'A-Z' 'a-z')
  [ "$recursive" != "0" -a "$recursive" != "no" ] && recurse="--recursive"

  # determine if $DEP points to a valid release or branch
  if ! git ls-remote --quiet --exit-code --refs $repourl "$TAG" > /dev/null 2>&1
  then
    echo "${ANSI_RED}$TAG is neither a tag nor a branch name for $DEP ($repourl)${ANSI_RESET}"
    [ "$UTILS_UNITTEST" ] || exit 1
  fi

  if [ -e $CACHEDIR/$dirname-$TAG ]
  then
    [ -e $CACHEDIR/$dirname-$TAG/built ] && BUILT=$(cat $CACHEDIR/$dirname-$TAG/built) || BUILT="never"
    HEAD=$(cd "$CACHEDIR/$dirname-$TAG" && git log -n1 --pretty=format:%H)
    if [ "$HEAD" != "$BUILT" ]
    then
      rm -fr $CACHEDIR/$dirname-$TAG
    else
      echo "Found $TAG of dependency $DEP in $CACHEDIR/$dirname-$TAG"
    fi
  fi

  if [ ! -e $CACHEDIR/$dirname-$TAG ]
  then
    cd $CACHEDIR
    eval depth=\${${DEP}_DEPTH:-"-1"}
    case ${depth} in
    -1 )
      deptharg="--depth 5"
      ;;
    0 )
      deptharg=""
      ;;
    * )
      deptharg="--depth $depth"
      ;;
    esac
    echo "Cloning $TAG of dependency $DEP into $CACHEDIR/$dirname-$TAG"
    git clone --quiet $deptharg $recurse --branch "$TAG" $repourl $dirname-$TAG
    ( cd $dirname-$TAG && git log -n1 )
    modules_to_compile="${modules_to_compile} $CACHEDIR/$dirname-$TAG"
    # run hook
    eval hook="\${${DEP}_HOOK}"
    if [ "$hook" ]
    then
      if [ -x "$curdir/$hook" ]
      then
        echo "Running hook $hook in $CACHEDIR/$dirname-$TAG"
        ( cd $CACHEDIR/$dirname-$TAG; "$curdir/$hook" )
      else
        echo "${ANSI_RED}Hook script $hook is not executable or does not exist.${ANSI_RESET}"
        exit 1
      fi
    fi
    HEAD=$(cd "$CACHEDIR/$dirname-$TAG" && git log -n1 --pretty=format:%H)
    echo "$HEAD" > "$CACHEDIR/$dirname-$TAG/built"
    cd "$curdir"
  fi

  update_release_local ${varname} $CACHEDIR/$dirname-$TAG
}
