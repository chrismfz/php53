# CloudLinux backported security patches

**Generated** by `tools/import-cloudlinux-patches.py` — do not hand-edit.
Re-run the tool on a newer SRPM and review `git diff patches/`.

## Source

- SRPM: `ea-php53-php-5.3.29-29.el8.cloudlinux.68.src.rpm`
- release: `29.el8.cloudlinux.68`
- sha256: `68e020d717943c6707641d723419655d01ea8080ae9c029997439a6aea030e5c`
- url: https://repo.cloudlinux.com/cloudlinux/EA4/8.1/updates/src/ea-php53-php-5.3.29-29.el8.cloudlinux.68.src.rpm

## What is kept

321 of 361 applied patches are kept and applied by the build (see `series`); the rest are CloudLinux/LiteSpeed/EA4 runtime or build-packaging patches we do not use (full list + reason in `MANIFEST.tsv`).

| category | kept | skipped |
|---|---|---|
| CVE | 152 | 0 |
| bug | 163 | 0 |
| build/packaging | 0 | 24 |
| forced | 1 | 0 |
| hardened | 5 | 0 |
| vendor/sapi | 0 | 16 |

## CVEs covered (151)

CVE-2011-4718, CVE-2011-4885, CVE-2012-0830, CVE-2013-7345, CVE-2014-1943, CVE-2014-2270, CVE-2014-2497, CVE-2014-3587, CVE-2014-3597, CVE-2014-3668, CVE-2014-3669, CVE-2014-3670, CVE-2014-3710, CVE-2014-4670, CVE-2014-4698, CVE-2014-8142, CVE-2014-9425, CVE-2014-9652, CVE-2014-9653, CVE-2014-9705, CVE-2014-9709, CVE-2014-9767, CVE-2015-0232, CVE-2015-0235, CVE-2015-0273, CVE-2015-2301, CVE-2015-2326, CVE-2015-2331, CVE-2015-2348, CVE-2015-2783, CVE-2015-2787, CVE-2015-3152, CVE-2015-3329, CVE-2015-3330, CVE-2015-3411, CVE-2015-4021, CVE-2015-4022, CVE-2015-4024, CVE-2015-4025, CVE-2015-4026, CVE-2015-4147, CVE-2015-4598, CVE-2015-4599, CVE-2015-4602, CVE-2015-4603, CVE-2015-4604, CVE-2015-5590, CVE-2015-6831, CVE-2015-6832, CVE-2015-6833, CVE-2015-6835, CVE-2015-6836, CVE-2015-6837, CVE-2015-6838, CVE-2015-7804, CVE-2015-8835, CVE-2015-8867, CVE-2015-8876, CVE-2015-8879, CVE-2016-2554, CVE-2016-3074, CVE-2016-4073, CVE-2016-4343, CVE-2016-4537, CVE-2016-4539, CVE-2016-4540, CVE-2016-4541, CVE-2016-4542, CVE-2016-5093, CVE-2016-5094, CVE-2016-5096, CVE-2016-5385, CVE-2016-5399, CVE-2016-5766, CVE-2016-5772, CVE-2016-6288, CVE-2016-6289, CVE-2016-6290, CVE-2016-6291, CVE-2016-6294, CVE-2016-6296, CVE-2016-6297, CVE-2016-7128, CVE-2016-7412, CVE-2016-7413, CVE-2016-7414, CVE-2016-7416, CVE-2016-7417, CVE-2016-7418, CVE-2016-7478, CVE-2016-8670, CVE-2016-8874, CVE-2016-10159, CVE-2016-10160, CVE-2016-10161, CVE-2017-7890, CVE-2017-9224, CVE-2017-9226, CVE-2017-9227, CVE-2017-9228, CVE-2017-9229, CVE-2017-11143, CVE-2017-11144, CVE-2017-11145, CVE-2018-14883, CVE-2018-17082, CVE-2018-19518, CVE-2018-19935, CVE-2018-20783, CVE-2019-9022, CVE-2019-9023, CVE-2019-9025, CVE-2019-11034, CVE-2019-11035, CVE-2019-11036, CVE-2019-11048, CVE-2019-13224, CVE-2019-19246, CVE-2020-7067, CVE-2020-7068, CVE-2020-7070, CVE-2020-7071, CVE-2021-21703, CVE-2021-21704, CVE-2021-21705, CVE-2021-21707, CVE-2022-31625, CVE-2022-31628, CVE-2022-31629, CVE-2022-31631, CVE-2023-0567, CVE-2023-0568, CVE-2023-0662, CVE-2023-3247, CVE-2023-3823, CVE-2023-3824, CVE-2024-2756, CVE-2024-8925, CVE-2024-8927, CVE-2024-8929, CVE-2024-11233, CVE-2024-11234, CVE-2024-11236, CVE-2025-1217, CVE-2025-1220, CVE-2025-6491, CVE-2026-6722, CVE-2026-6735, CVE-2026-7261, CVE-2026-7262, CVE-2026-14355

## Skipped (40)

- `0001-Update-libxml-include-file-references.patch` — build/packaging glue, not a source security/bug backport
- `0002-libxml2.15-compatibility.patch` — build/packaging glue, not a source security/bug backport
- `cloudlinux-php-fpm.5.3.dl.ea-php.v3.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `litespeed-8.0.1-graceful_stop.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `litespeed-8.0.1-log.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `litespeed-8.0.1-move_override_ini.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `litespeed-8.0.1-process_lsapi_phpini.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `litespeed-8.0.1-tsrmls.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `litespeed-8.0.1-userini_homedir.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `litespeed-8.0.1.avoid_zombies.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `litespeed-8.0.1.crash_limit.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `litespeed-8.0.1.dis_keeplistener.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `litespeed-8.0.1.use_reject.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `litespeed-8.0.1.wink_fix.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `litespeed-8.1-cloudlinux.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `litespeed-8.3-document_root_env.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `php-4.3.11-shutdown.patch` — build/packaging glue, not a source security/bug backport
- `php-5.0.4-dlopen.patch` — build/packaging glue, not a source security/bug backport
- `php-5.0.4-tests-wddx.patch` — build/packaging glue, not a source security/bug backport
- `php-5.2.0-includedir.patch` — build/packaging glue, not a source security/bug backport
- `php-5.2.4-embed.patch` — build/packaging glue, not a source security/bug backport
- `php-5.2.4-norpath.patch` — build/packaging glue, not a source security/bug backport
- `php-5.3.0-easter.patch` — build/packaging glue, not a source security/bug backport
- `php-5.3.0-install.patch` — build/packaging glue, not a source security/bug backport
- `php-5.3.0-phpize64.patch` — build/packaging glue, not a source security/bug backport
- `php-5.3.0-recode.patch` — build/packaging glue, not a source security/bug backport
- `php-5.3.12-aconf26x.patch` — build/packaging glue, not a source security/bug backport
- `php-5.3.29-bug_arginfo_bzcompress.patch` — build/packaging glue, not a source security/bug backport
- `php-5.3.29-core4zend_mm_panic.patch` — build/packaging glue, not a source security/bug backport
- `php-5.3.29-openssl11.patch` — build/packaging glue, not a source security/bug backport
- `php-5.3.29-sybase_ct-libdir.patch` — build/packaging glue, not a source security/bug backport
- `php-5.3.29-test_exit_code.patch` — build/packaging glue, not a source security/bug backport
- `php-5.3.29-wordpress-update-url.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `php-5.3.3-gnusrc.patch` — build/packaging glue, not a source security/bug backport
- `php-5.3.x-mail-header.patch` — build/packaging glue, not a source security/bug backport
- `php-5.4.x-fpm-jailshell.patch` — CloudLinux/LiteSpeed/EA4 runtime- or SAPI-specific
- `php-5.4.x-fpm-user-ini-docroot.patch` — build/packaging glue, not a source security/bug backport
- `php-5.x-disable-zts.patch` — build/packaging glue, not a source security/bug backport
- `php-8.2-fix-for-libxml2.13.patch` — build/packaging glue, not a source security/bug backport
- `php-fpm.epoll.patch` — build/packaging glue, not a source security/bug backport
