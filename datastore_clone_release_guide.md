# Datastore Clone Release Guide

## 1. Set GCP project

``` bash
gcloud config set project netflixauth-442114
```

## 2. Verify databases

``` bash
gcloud firestore databases list
```

Expected: - Source database: `(default)` - Clone database:
`digitallibrabry-datastore` 

## 3. Clone database

Create the clone in Google Cloud Console:

1.  Open **Datastore → All databases**.
2.  On database `(default)`, click **Actions (⋮) → Clone**.
3.  Database ID: `digitallibrabry-datastore`
4.  Select the required **Clone from** timestamp. The timestamp must be
    within the available window shown in the UI.
5.  Click **Create Clone**.

> The destination database ID must not already exist.

## 4. Trace clone progress

List operations for the cloned database:

``` bash
gcloud firestore operations list --database=digitallibrabry-datastore
```

Describe the clone operation using the operation ID returned by the
database metadata or operations list:

``` bash
gcloud firestore operations describe OPERATION_ID --database=digitallibrabry-datastore
```

Replace `OPERATION_ID` with the actual operation ID. Stop polling with
`Ctrl+C`.

## 5. Verify clone completion

``` bash
gcloud firestore operations describe OPERATION_ID --database=digitallibrabry-datastore
```

Confirm the operation reports `done: true` and no error.

``` bash
gcloud firestore databases describe --database=digitallibrabry-datastore
```

``` bash
gcloud firestore databases list
```

## 6. Clone details

-   Source database: `(default)`
-   Destination database: `digitallibrabry-datastore`
