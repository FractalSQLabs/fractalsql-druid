Name:           fractalsql-druid
Version:        %{?pkg_version}%{!?pkg_version:2.0.0}
Release:        1%{?dist}
Summary:        FractalSQL for Apache Druid: the extension, fractalsqld and the MCP server
License:        Apache-2.0
Vendor:         FractalSQLabs
Packager:       FractalSQLabs <ops@fractalsqlabs.io>
URL:            https://github.com/FractalSQLabs/fractalsql-druid
Requires:       (java-17-openjdk-headless or java-21-openjdk-headless or java-25-openjdk-headless), libcurl, openssl-libs
%description
The Druid extension JAR, fractalsqld (the reasoning, embedding and enterprise service that
runs beside the Druid brokers), and fractalsql-druid-mcp (a Model Context Protocol server).

%prep
%build
%install
# The bundle is staged by scripts/package.sh and unpacked into %{_sourcedir}/stage.
S=%{_sourcedir}/stage
mkdir -p %{buildroot}/usr/lib/fractalsql-druid %{buildroot}/usr/bin %{buildroot}/etc/fractalsql %{buildroot}/usr/lib/systemd/system %{buildroot}/usr/share/doc/fractalsql-druid
cp -r $S/extensions $S/fractalsqld $S/mcp %{buildroot}/usr/lib/fractalsql-druid/
install -m 0755 $S/bin/fractalsqld $S/bin/fsqlctl $S/bin/fractalsql-druid-mcp %{buildroot}/usr/bin/
install -m 0755 $S/bin/fractalsql-ledger-collect $S/bin/fractalsql-ledger-check %{buildroot}/usr/bin/
install -m 0644 $S/bin/.mcp-schema-lock $S/bin/.mcp-safety-annotations-lock %{buildroot}/usr/bin/
install -m 0640 $S/conf/fractalsqld.conf.example %{buildroot}/etc/fractalsql/fractalsqld.conf
install -m 0644 $S/conf/fractalsqld.service %{buildroot}/usr/lib/systemd/system/
install -m 0644 $S/docs/*.md %{buildroot}/usr/share/doc/fractalsql-druid/
install -m 0644 $S/LICENSE $S/THIRD-PARTY-NOTICES.md %{buildroot}/usr/share/doc/fractalsql-druid/

%pre
getent group fractalsql >/dev/null || groupadd -r fractalsql
getent passwd fractalsql >/dev/null || useradd -r -g fractalsql -d /var/lib/fractalsql -s /sbin/nologin fractalsql

%post
install -d -o fractalsql -g fractalsql -m 0750 /var/lib/fractalsql
chown root:fractalsql /etc/fractalsql/fractalsqld.conf
if [ ! -f /etc/fractalsql/hmac.key ]; then
  umask 027
  od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > /etc/fractalsql/hmac.key
  chown root:fractalsql /etc/fractalsql/hmac.key
fi
systemctl daemon-reload >/dev/null 2>&1 || :

%preun
if [ $1 -eq 0 ]; then systemctl stop fractalsqld >/dev/null 2>&1 || :; fi

%files
/usr/lib/fractalsql-druid
/usr/bin/fractalsqld
/usr/bin/fsqlctl
/usr/bin/fractalsql-druid-mcp
/usr/bin/fractalsql-ledger-collect
/usr/bin/fractalsql-ledger-check
/usr/bin/.mcp-schema-lock
/usr/bin/.mcp-safety-annotations-lock
%config(noreplace) %attr(0640,root,fractalsql) /etc/fractalsql/fractalsqld.conf
/usr/lib/systemd/system/fractalsqld.service
%dir /usr/share/doc/fractalsql-druid
%doc /usr/share/doc/fractalsql-druid/*.md
%license /usr/share/doc/fractalsql-druid/LICENSE
