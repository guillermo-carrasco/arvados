# Arvados base image (wheezy+rvm+Arvados source) in Docker

# Based on Debian Wheezy
FROM arvados/debian:wheezy
MAINTAINER Tim Pierce <twp@curoverse.com>

ENV DEBIAN_FRONTEND noninteractive

# Install prerequisite packages for Arvados
#   * git, curl, rvm
#   * Arvados source code in /usr/src/arvados, for preseeding gem installation

RUN apt-get update && \
    apt-get -q -y install -q -y openssh-server apt-utils git curl \
             libcurl3 libcurl3-gnutls libcurl4-openssl-dev locales \
             postgresql-server-dev-9.1 && \
    /bin/mkdir -p /root/.ssh && \
    /bin/sed -ri 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    /usr/sbin/locale-gen && \
    curl -L https://get.rvm.io | bash -s stable && \
    /usr/local/rvm/bin/rvm install 2.1.0 && \
    /bin/mkdir -p /usr/src/arvados

ADD generated/arvados.tar.gz /usr/src/arvados/

# Set up RVM environment. These are just the env variables created by
# /usr/local/rvm/scripts/rvm, which can't be run from a non-login shell.
# TODO(twp): figure out a less awful solution.
ENV GEM_HOME /usr/local/rvm/gems/ruby-2.1.0
ENV GEM_PATH /usr/local/rvm/gems/ruby-2.1.0:/usr/local/rvm/gems/ruby-2.1.0@global
ENV PATH /usr/local/rvm/gems/ruby-2.1.0/bin:/usr/local/rvm/gems/ruby-2.1.0@global/bin:/usr/local/rvm/rubies/ruby-2.1.0/bin:/usr/local/rvm/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Update gem. This (hopefully) fixes
# https://github.com/rubygems/rubygems.org/issues/613.
RUN gem update --system && \
    gem install bundler && \
    bundle install --gemfile=/usr/src/arvados/apps/workbench/Gemfile && \
    bundle install --gemfile=/usr/src/arvados/services/api/Gemfile && \
    bundle install --gemfile=/usr/src/arvados/doc/Gemfile

ADD generated/id_rsa.pub /root/.ssh/authorized_keys
RUN chown root:root /root/.ssh/authorized_keys
