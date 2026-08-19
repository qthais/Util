# Util
Elasticsearch ES6 → ES9: Sort Breaking Changes

|Sort feature                   |ES6         |ES7             |ES8|ES9|Risk|Ref                                                                                                                           |
|-------------------------------|:----------:|:--------------:|:-:|:-:|:--:|------------------------------------------------------------------------------------------------------------------------------|
|`_id` sort                     |⚠️           |⚠️ deprecated 7.6|❌  |❌  |🔴   |[ES8 migration — `_id` sorting](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/migrating-8.0.html)              |
|`_type` sort                   |⚠️ legacy    |❌               |❌  |❌  |🔴   |[Removal of mapping types](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/removal-of-types.html)                |
|`_uid` sort                    |⚠️ legacy    |❌               |❌  |❌  |🔴   |[Removal of mapping types](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/removal-of-types.html)                |
|`unmapped_type: string`        |✅           |⚠️               |❌  |❌  |🔴   |[ES8 migration — `unmapped_type: string`](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/migrating-8.0.html)    |
|`nested_path` / `nested_filter`|⚠️ deprecated|⚠️ deprecated    |❌  |❌  |🔴   |[ES8 migration — removed nested sort options](https://www.elastic.co/guide/en/elasticsearch/reference/8.19/migrating-8.0.html)|

Migration notes

• _id: sorting and aggregating on _id was deprecated in ES 7.6 and is disallowed by default in ES 8. Use a normal field with doc_values instead.
• _type / _uid: tied to the removal of mapping types. Mapping types are no longer supported in ES 8.
• unmapped_type: string: removed in ES 8. Use unmapped_type: keyword.
• nested_path / nested_filter: deprecated in ES 6.x and removed in ES 8. Use the nested sort context with path and filter.

Primary references

• Elasticsearch 8.0 Migration Guide
• Removal of Mapping Types
• Elasticsearch 8.0 Release Notes
• Sort Search Results