from pathlib import Path

p = Path('build-php53.sh')
t = p.read_text(encoding='utf-8')

replacements = [
    ('        libpq-devel openldap-devel cyrus-sasl-devel libtidy-devel aspell-devel net-snmp-devel net-snmp-utils \\\n',
     '        libpq-devel openldap-devel cyrus-sasl-devel libtidy-devel aspell-devel \\\n'),
    ('      --with-snmp \\\n', ''),
    (' pgsql pdo_pgsql ldap tidy pspell snmp sqlite3 pdo_sqlite zip;',
     ' pgsql pdo_pgsql ldap tidy pspell sqlite3 pdo_sqlite zip;'),
]

for old, new in replacements:
    if old not in t:
        raise SystemExit('expected builder fragment not found: %r' % old)
    t = t.replace(old, new, 1)

p.write_text(t, encoding='utf-8')
