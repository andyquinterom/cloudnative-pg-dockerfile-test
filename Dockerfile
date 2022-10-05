# Stage for building Oracle Foreign Data Wrapper
FROM postgres:14-bullseye AS oic_builder

RUN apt-get update -y && apt-get upgrade -y
RUN apt-get install -y libaio1 alien wget unzip libpq-dev postgresql-server-dev-14
ENV OIC_BASIC_RPM oracle-instantclient-basic-21.7.0.0.0-1.el8.x86_64.rpm
RUN wget https://download.oracle.com/otn_software/linux/instantclient/217000/${OIC_BASIC_RPM}
RUN alien -i --scripts ${OIC_BASIC_RPM}
RUN rm -r ${OIC_BASIC_RPM}
ENV OIC_SDK_RPM oracle-instantclient-devel-21.7.0.0.0-1.el8.x86_64.rpm
RUN wget https://download.oracle.com/otn_software/linux/instantclient/217000/${OIC_SDK_RPM}
RUN alien -i --scripts ${OIC_SDK_RPM}
RUN rm -r ${OIC_SDK_RPM}

ENV ORACLE_FDW ORACLE_FDW_2_4_0
RUN wget https://github.com/laurenz/oracle_fdw/archive/refs/tags/${ORACLE_FDW}.zip
RUN unzip ${ORACLE_FDW}.zip
RUN cd oracle_fdw-${ORACLE_FDW} && make && make install

# Stage for building Tds Foreign Data Wrapper for connections with SQL Server
FROM postgres:14-bullseye AS tds_builder

RUN apt-get update -y && apt-get upgrade -y
RUN apt-get install -y gcc libsybdb5 freetds-dev freetds-common wget libpq-dev postgresql-server-dev-14 make
ENV TDS_FDW_VERSION "2.0.2"
RUN wget https://github.com/tds-fdw/tds_fdw/archive/refs/tags/v${TDS_FDW_VERSION}.tar.gz
RUN tar -xvzf v${TDS_FDW_VERSION}.tar.gz
RUN cd tds_fdw-${TDS_FDW_VERSION}/ && make USE_PGXS=1 && make USE_PGXS=1 install

# Build a Citus compatible image for CloudNativePg.
# I based myself on the official Citus image and the CloudNativePg
# Postgres-containers repository.
# https://github.com/cloudnative-pg/postgres-containers
# https://github.com/citusdata/docker
FROM postgres:14-bullseye
ARG VERSION=11.1.2

ENV CITUS_VERSION ${VERSION}.citus-1

# install Citus and pgaudit
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates \
       curl \
    && curl -s https://install.citusdata.com/community/deb.sh | bash \
    && apt-get install -y --no-install-recommends \
                          postgresql-$PG_MAJOR-pgaudit \
                          postgresql-$PG_MAJOR-citus-11.1=$CITUS_VERSION \
                          postgresql-$PG_MAJOR-hll=2.16.citus-1 \
                          postgresql-$PG_MAJOR-topn=2.4.0 \
                          libaio1 libsybdb5 freetds-dev freetds-common \
    && apt-get purge -y --auto-remove curl \
    && rm -fr /tmp/* \
    && rm -rf /var/lib/apt/lists/*

RUN echo "shared_preload_libraries='citus'" >> /usr/share/postgresql/postgresql.conf.sample

COPY 001-create-citus-extension.sql /docker-entrypoint-initdb.d/

# Copy files from oracle_fdw and tds_fdw
COPY --from=oic_builder /usr/lib/postgresql/14/lib/oracle_fdw.so /usr/lib/postgresql/14/lib/
COPY --from=oic_builder /usr/share/doc/postgresql-doc-14/extension/README.oracle_fdw /usr/share/doc/postgresql-doc-14/extension/
COPY --from=oic_builder /usr/share/postgresql/14/extension/oracle_fdw* /usr/share/postgresql/14/extension/
COPY --from=oic_builder /usr/lib/oracle /usr/lib/oracle
COPY --from=oic_builder /usr/include/oracle /usr/include/oracle

COPY --from=tds_builder /usr/lib/postgresql/14/lib/tds_fdw.so /usr/lib/postgresql/14/lib/
COPY --from=tds_builder /usr/share/doc/postgresql-doc-14/extension/README.tds_fdw.md /usr/share/doc/postgresql-doc-14/extension/
COPY --from=tds_builder /usr/share/postgresql/14/extension/tds_fdw* /usr/share/postgresql/14/extension/
COPY --from=tds_builder /usr/lib/postgresql/14/lib/bitcode/tds_fdw/src /usr/lib/postgresql/14/lib/bitcode/tds_fdw/src

ENV LD_LIBRARY_PATH=/usr/lib/oracle/21/client64/lib/
ENV ORACLE_HOME=/usr/lib/oracle/21/client64/lib/

COPY requirements.txt /

# Install barman-cloud
RUN set -xe; \
	apt-get update; \
	apt-get install -y --no-install-recommends \
		python3-pip \
		python3-psycopg2 \
		python3-setuptools \
	; \
	pip3 install --upgrade pip; \
# TODO: Remove --no-deps once https://github.com/pypa/pip/issues/9644 is solved
	pip3 install --no-deps -r requirements.txt; \
	rm -rf /var/lib/apt/lists/*;

# Change the uid of postgres to 26
RUN usermod -u 26 postgres
USER 26
