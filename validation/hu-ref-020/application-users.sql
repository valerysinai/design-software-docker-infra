-- Only the disposable hu_ref_020 database is supported by this runner.
SELECT current_database() = 'hu_ref_020' AS isolated_database \gset
\if :isolated_database
\else
  \echo Wrong database; application users were not changed.
  \quit 1
\endif
\getenv iam_password IAM_APP_PASSWORD
\getenv reference_password REFERENCE_APP_PASSWORD
SELECT 'CREATE ROLE hu020_iam LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hu020_iam') \gexec
SELECT 'CREATE ROLE hu020_reference LOGIN' WHERE NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'hu020_reference') \gexec
ALTER ROLE hu020_iam PASSWORD :'iam_password';
ALTER ROLE hu020_reference PASSWORD :'reference_password';
GRANT iam_writer TO hu020_iam;
GRANT reference_writer TO hu020_reference;
