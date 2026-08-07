from pathlib import Path

p = Path('build-php53.sh')
t = p.read_text(encoding='utf-8')

for forbidden in ('net-snmp', 'libsnmp-dev', '--with-snmp'):
    if forbidden in t:
        raise SystemExit('SNMP fragment still present: %s' % forbidden)

old = 'libpq-devel openldap-devel cyrus-sasl-devel libtidy-devel aspell-devel \\\n\n'
new = 'libpq-devel openldap-devel cyrus-sasl-devel libtidy-devel aspell-devel\n'
if old not in t:
    raise SystemExit('expected trailing dnf continuation not found')
t = t.replace(old, new, 1)

p.write_text(t, encoding='utf-8')
