DROP TABLE IF EXISTS people;
DROP TABLE IF EXISTS people_names;

CREATE TABLE IF NOT EXISTS people(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  fname TEXT NOT NULL,
  lname TEXT NOT NULL,
  email TEXT UNIQUE NOT NULL,
  age INT NOT NULL,
  sex
);

CREATE VIEW IF NOT EXISTS people_names AS
  SELECT concat_ws(' ',lname,fname) AS name
  FROM people;
