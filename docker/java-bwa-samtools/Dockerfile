FROM arvados/jobs
MAINTAINER Peter Amstutz <peter.amstutz@curoverse.com>

USER root

RUN apt-get install -y -q openjdk-7-jre-headless && \
    cd /tmp && \
    curl --location http://downloads.sourceforge.net/project/bio-bwa/bwa-0.7.9a.tar.bz2 -o bwa-0.7.9a.tar.bz2 && \
    tar xjf bwa-0.7.9a.tar.bz2 && \
    cd bwa-0.7.9a && \
    make && \
    (find . -executable -type f -print0 | xargs -0 -I {} mv {} /usr/local/bin) && \
    rm -r /tmp/bwa-0.7.9a* && \
    cd /tmp && \
    curl --location http://downloads.sourceforge.net/project/samtools/samtools/0.1.19/samtools-0.1.19.tar.bz2 -o samtools-0.1.19.tar.bz2 && \
    tar xjf samtools-0.1.19.tar.bz2 && \
    cd samtools-0.1.19 && \
    make && \
    (find . -executable -type f -print0 | xargs -0 -I {} mv {} /usr/local/bin) && \
    rm -r /tmp/samtools-0.1.19*

USER crunch