from pathlib import Path

p = Path('build-php53.sh')
t = p.read_text(encoding='utf-8')

checks = {
    'dnf snmp deps': '        net-snmp-devel net-snmp-utils',
    'apt snmp dep': ' libsnmp-dev',
    'configure flag': '      --with-snmp \\\n',
    'verification module': ' pspell snmp sqlite3',
}
for label, needle in checks.items():
    if needle not in t:
        raise SystemExit('%s not found: %r' % (label, needle))

t = t.replace('        net-snmp-devel net-snmp-utils', '', 1)
t = t.replace(' libsnmp-dev', '', 1)
t = t.replace('      --with-snmp \\\n', '', 1)
t = t.replace(' pspell snmp sqlite3', ' pspell sqlite3', 1)

p.write_text(t, encoding='utf-8')
