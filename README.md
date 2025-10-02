# Multilingual_Text_to_SQL [TO BE UPDATED]

Small collection of multilingual Natural Language -> SQL (text-to-SQL) question datasets and database schemas used for experimentation and evaluation **[TO BE UPDATED]**.

## Layout

- [databases/](databases/) — exported BigQuery, Snowflake, and SQLite schemas and JSON/DDL metadata for multiple public datasets.
- [questions/](questions/) — multilingual question files in JSONL format. Each line is a single JSON object describing a natural language query and target database.

## Purpose

This repo aggregates:
- Database table definitions and samples to help map natural language questions to schema elements.
- Multilingual question sets cover 8 languages (en, de, es, fr, ja, pt, vi, zh) intended for training/evaluating text-to-SQL systems.

## Usage

1. Inspect database schemas in [databases/](databases/).
2. Open question files in [questions/](questions/) to view examples of NL queries and associated db ids.
   - Example: [questions/spider2-lite_vi.jsonl](questions/spider2-lite_vi.jsonl)
3. Use the schemas to generate SQL templates or to build mapping layers for your parser.

## Contributing

- Add new schemas under `databases/<engine>/<dataset>/`.
- Add multilingual question files under `questions/` as JSONL, one JSON object per line.
- Keep schema DDL and JSON metadata aligned.

## Notes

- Files in `databases/` include descriptive JSON metadata (and may have DDL.csv) that help identify table and column names for SQL generation.
- Question files contain instance ids and the target `db` name matching directory names under `databases/`.