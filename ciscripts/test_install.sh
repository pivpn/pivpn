#!/bin/bash -e

if [[ "$TRAVIS_EVENT_TYPE" == "pull_request" ]]; then
  echo "Pull Request, testing branch $TRAVIS_PULL_REQUEST_BRANCH on $TRAVIS_PULLREQUEST_SLUG"
  sudo ./auto_install/install.sh --giturl https://github.com/"${TRAVIS_PULL_REQUEST_SLUG}" \
    --gitbranch "${TRAVIS_PULL_REQUEST_BRANCH}" \
    --unattended ciscripts/ci_"${VPNPROTO}".conf
else
  if [[ "$TRAVIS_BRANCH" == "test" ]]; then
    echo "Testing PiVPN Test branch"
    sudo TESTING= ./auto_install/install.sh --unattended ciscripts/ci_"${VPNPROTO}".conf
  else
    echo "Testing PiVPN Master branch"
    sudo ./autoinstall.sh --unattended ciscripts/ci_"${VPNPROTO}".conf
  fi
fi
