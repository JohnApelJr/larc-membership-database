/* ============================================================
   HAM_Radio_LARC — Amateur Radio Club Membership Database
   Platform  : Microsoft SQL Server (T-SQL)
   Author    : John (W2SO Project Team)
   Version   : 4.0 (Portfolio Edition)

   PROJECT OVERVIEW
   ----------------
   This database was designed for the Livingston Amateur Radio Club
   (LARC) to replace a flat-file spreadsheet system. It normalizes
   member records, license classes, contact information, dues payments,
   physical key access, and club officer roles into a fully relational
   schema meeting 3NF (Third Normal Form).

   SCHEMA OVERVIEW (9 tables)
   ---------------------------
     Licenses            — FCC license class lookup (Technician / General / Extra)
     Membership_Types    — Member category lookup (Active / New / Silent Key)
     Membership_Dates    — Begin and expiration date tracking per member
     Contact_Infos       — Normalized address, phone, and email records
     Members             — Core member entity; FK hub for all lookup tables
     Keys                — Physical facility keys issued by the club
     Key_Holders         — Associative/bridge table: Members ↔ Keys (M:M)
     Club_Officers       — Officer roles tied to member records
     Membership_Dues     — Dues payment ledger; drives expiration via trigger

   SCRIPT STRUCTURE
   ----------------
     SECTION 1  — Database creation
     SECTION 2  — Raw data staging: import, deduplicate, enrich
     SECTION 3  — Schema UP: create all tables + constraints
     SECTION 4  — Data pipeline: seed tables from staged roster
     SECTION 5  — Computed columns: volunteer status, membership badge
     SECTION 6  — Trigger: auto-update expiration on dues payment
     SECTION 7  — Indexes: tuned for common query patterns
     SECTION 8  — Views: business-facing read layer
     SECTION 9  — Sample analytical queries
     SECTION 10 — Schema DOWN: safe teardown in dependency order
   ============================================================ */


/* ============================================================
   SECTION 1 — DATABASE CREATION
   ============================================================ */

CREATE DATABASE HAM_Radio_LARC;
GO
USE HAM_Radio_LARC;
GO


/* ============================================================
   SECTION 2 — RAW DATA STAGING
   Source: membership_roster.csv imported via SSMS Import Wizard
           into [dbo].[Membership Roster] (staging table).

   Steps performed here:
     a) Remove duplicate rows flagged during import review.
     b) Add a Club_Officer column and populate it manually —
        officer data did not exist in the original CSV and was
        sourced from club records.
   ============================================================ */

-- (a) Remove known duplicates that were tagged during data review.
--     The import wizard flagged them with Middle_Initial = 'DUPLICATE'.
DELETE FROM [dbo].[Membership Roster]
WHERE Middle_Initial = 'DUPLICATE';
GO

-- (b) Add the Club_Officer column to carry officer data through
--     the pipeline before it is split into its own normalized table.
ALTER TABLE [dbo].[Membership Roster]
    ADD Club_Officer VARCHAR(50) NULL;
GO

-- Elected Officers
UPDATE [dbo].[Membership Roster] SET Club_Officer = 'President'      WHERE First_Name = 'David'     AND Last_Name = 'Sepulveda';
UPDATE [dbo].[Membership Roster] SET Club_Officer = 'Vice President' WHERE First_Name = 'Salvatore'  AND Last_Name = 'Zarbo';
UPDATE [dbo].[Membership Roster] SET Club_Officer = 'Treasurer'      WHERE First_Name = 'Thomas'     AND Last_Name = 'Webb Jr.';
UPDATE [dbo].[Membership Roster] SET Club_Officer = 'Secretary'      WHERE First_Name = 'Genevieve'  AND Last_Name = 'Griesbaum';

-- Board of Directors
UPDATE [dbo].[Membership Roster] SET Club_Officer = 'Director' WHERE First_Name = 'Charles' AND Last_Name = 'Lawson';
UPDATE [dbo].[Membership Roster] SET Club_Officer = 'Director' WHERE First_Name = 'Ryan'    AND Last_Name = 'Buono';
UPDATE [dbo].[Membership Roster] SET Club_Officer = 'Director' WHERE First_Name = 'Robert'  AND Last_Name = 'Delamater';
UPDATE [dbo].[Membership Roster] SET Club_Officer = 'Director' WHERE First_Name = 'Joseph'  AND Last_Name = 'Fox Jr.';

-- Appointed Chairmen
--   Call sign included for Luke Calianno because there are two members
--   sharing that name; this makes the match unambiguous.
UPDATE [dbo].[Membership Roster] SET Club_Officer = 'Hamfest Chairman'       WHERE First_Name = 'Luke'     AND Last_Name = 'Calianno'  AND Call_Sign = 'N2GDU';
UPDATE [dbo].[Membership Roster] SET Club_Officer = 'Membership Chairman'    WHERE First_Name = 'David'    AND Last_Name = 'Ladd';
UPDATE [dbo].[Membership Roster] SET Club_Officer = 'Club Property Chairman' WHERE First_Name = 'Timothy'  AND Last_Name = 'Poliniak';
GO


/* ============================================================
   SECTION 3 — SCHEMA: TABLE CREATION (UP SCRIPT)

   Design note — Normalization strategy
   ------------------------------------
   The original flat CSV contained repeated values for license
   class, membership type, and contact details. These were
   extracted into lookup / dimension tables and replaced with
   foreign keys in Members. This eliminates update anomalies
   (e.g., changing "Technician" to "Tech" in one row only) and
   reduces storage for repeated string values.

   Table creation order respects FK dependencies:
     Lookup tables first → Members → Bridge / child tables.
   ============================================================ */

-- -------------------------------------------------------------
-- 3a. Licenses
--     Lookup table for FCC amateur radio license classes.
--     UNIQUE constraint on license_type_name ensures no
--     duplicate class names can be inserted.
-- -------------------------------------------------------------
CREATE TABLE Licenses (
    license_id        INT          IDENTITY(1,1) PRIMARY KEY,
    license_type_name VARCHAR(20)  NOT NULL UNIQUE
        -- Allowed values sourced from FCC: Technician, General, Extra
);
GO

-- -------------------------------------------------------------
-- 3b. Membership_Types
--     Lookup table for the three LARC membership categories.
--     'Silent Key' is amateur radio tradition for a deceased member.
-- -------------------------------------------------------------
CREATE TABLE Membership_Types (
    membership_type_id   INT         IDENTITY(1,1) PRIMARY KEY,
    membership_type_name VARCHAR(50) NOT NULL UNIQUE
        -- Values: 'New Member - Free', 'Regular Active - Paid', 'Silent Key'
);
GO

-- -------------------------------------------------------------
-- 3c. Membership_Dates
--     Tracks when a member joined, the date their prior membership
--     expired (historical reference), and their current expiration.
--     expiration_date is nullable because new members may not yet
--     have a set expiration.
--     prior_date captures the previous cycle expiration for audit trail.
-- -------------------------------------------------------------
CREATE TABLE Membership_Dates (
    date_id         INT  IDENTITY(1,1) PRIMARY KEY,
    begin_date      DATE NOT NULL,
    prior_date      DATE NULL,       -- Prior cycle expiration (historical)
    expiration_date DATE NULL        -- Updated automatically by trigger (Section 6)
);
GO

-- -------------------------------------------------------------
-- 3d. Contact_Infos
--     Stores all contact and address data separately from Members.
--     Separating this allows one address record to be shared if
--     a household has multiple members, avoiding redundant storage.
-- -------------------------------------------------------------
CREATE TABLE Contact_Infos (
    contact_info_id INT          IDENTITY(1,1) PRIMARY KEY,
    address         VARCHAR(255) NULL,
    city            VARCHAR(100) NULL,
    state           CHAR(2)      NULL,
    zipcode         VARCHAR(10)  NULL,
    email           VARCHAR(100) NULL,   -- NULL allowed; not all members have email
    phone           VARCHAR(15)  NULL
);
GO

-- -------------------------------------------------------------
-- 3e. Members  (core entity — FK hub)
--     References all four lookup/dimension tables above.
--     call_sign is the member's FCC-assigned radio identifier;
--     it is nullable because new licensees may not have one yet,
--     and VARCHAR(15) accommodates edge cases (e.g., 'pending').
--
--     member_vol_status and member_badge are added via ALTER
--     after the initial load so they can be computed from data
--     already in the table (see Section 5).
-- -------------------------------------------------------------
CREATE TABLE Members (
    member_id          INT         IDENTITY(1,1) PRIMARY KEY,
    last_name          VARCHAR(50) NOT NULL,
    first_name         VARCHAR(50) NOT NULL,
    middle_initial     VARCHAR(20) NULL,
    call_sign          VARCHAR(15) NULL,   -- FCC callsign; nullable for new/unlicensed
    license_id         INT         NULL    REFERENCES Licenses(license_id),
    membership_type_id INT         NOT NULL REFERENCES Membership_Types(membership_type_id),
    contact_info_id    INT         NOT NULL REFERENCES Contact_Infos(contact_info_id),
    membership_date_id INT         NOT NULL REFERENCES Membership_Dates(date_id)
);
GO

-- -------------------------------------------------------------
-- 3f. Keys
--     Represents physical facility keys issued by the club.
--     key_access_type is constrained to three valid values via CHECK.
-- -------------------------------------------------------------
CREATE TABLE Keys (
    key_id          INT         IDENTITY(1,1) PRIMARY KEY,
    key_number      VARCHAR(10) NOT NULL UNIQUE,
    key_issue_date  DATE        NOT NULL,
    key_access_type VARCHAR(20) NULL
        CHECK (key_access_type IN ('Front Door', 'Repeater Room', 'None'))
);
GO

-- -------------------------------------------------------------
-- 3g. Key_Holders  (bridge / associative entity)
--     Resolves the many-to-many relationship between Members and Keys.
--     A member can hold multiple keys; a key type can be held by
--     multiple members. The composite PK enforces uniqueness on
--     the pairing. CASCADE DELETE keeps the bridge clean if
--     either parent row is removed.
-- -------------------------------------------------------------
CREATE TABLE Key_Holders (
    member_id INT NOT NULL REFERENCES Members(member_id) ON DELETE CASCADE,
    key_id    INT NOT NULL REFERENCES Keys(key_id)       ON DELETE CASCADE,
    PRIMARY KEY (member_id, key_id)
        -- Composite PK prevents a member from being assigned
        -- the same key record more than once.
);
GO

-- -------------------------------------------------------------
-- 3h. Club_Officers
--     Links members to their elected or appointed role.
--     A member can only hold one role at a time in this model
--     (one row per officer). officer_role is CHECK-constrained
--     to the nine recognized LARC positions.
-- -------------------------------------------------------------
CREATE TABLE Club_Officers (
    club_officer_id INT         IDENTITY(1,1) PRIMARY KEY,
    member_id       INT         NOT NULL REFERENCES Members(member_id) ON DELETE CASCADE,
    officer_role    VARCHAR(25) NULL
        CHECK (officer_role IN (
            'President', 'Vice President', 'Treasurer', 'Secretary',
            'Director', 'Hamfest Chairman', 'Membership Chairman',
            'Donations Chairman', 'Club Property Chairman'
        ))
);
GO

-- -------------------------------------------------------------
-- 3i. Membership_Dues
--     Payment ledger: one row per payment event per member.
--     payment_date defaults to GETDATE() so inserts without an
--     explicit date record correctly.
--     The AFTER INSERT trigger (Section 6) reads from this table
--     to automatically roll forward the member's expiration date.
-- -------------------------------------------------------------
CREATE TABLE Membership_Dues (
    payment_id   INT           IDENTITY(1,1) PRIMARY KEY,
    member_id    INT           NOT NULL REFERENCES Members(member_id) ON DELETE CASCADE,
    payment_date DATE          NOT NULL DEFAULT GETDATE(),
    amount       DECIMAL(10,2) NOT NULL
);
GO


/* ============================================================
   SECTION 4 — DATA PIPELINE: SEED TABLES FROM STAGED ROSTER

   Each lookup table is populated first using SELECT DISTINCT
   so that only unique values from the raw CSV become rows.
   Members is populated last because it depends on all FKs
   being resolved via correlated subqueries.
   ============================================================ */

-- Seed Licenses from distinct values in the staging table
INSERT INTO Licenses (license_type_name)
SELECT DISTINCT [License_Class]
FROM [HAM_Radio_LARC].[dbo].[Membership Roster]
WHERE [License_Class] IS NOT NULL;
GO

-- Seed Membership_Types
INSERT INTO Membership_Types (membership_type_name)
SELECT DISTINCT [LARC_Membership_Type]
FROM [HAM_Radio_LARC].[dbo].[Membership Roster]
WHERE [LARC_Membership_Type] IS NOT NULL;
GO

-- Seed Membership_Dates
--   begin_date is set to GETDATE() (import date) because the CSV
--   did not carry an original join date for all members.
--   prior_date and expiration_date come directly from the CSV columns.
INSERT INTO Membership_Dates (begin_date, prior_date, expiration_date)
SELECT DISTINCT
    GETDATE()                      AS begin_date,
    [Prior_Membership_Expiration]  AS prior_date,
    [Next_Membership_Expiration]   AS expiration_date
FROM [HAM_Radio_LARC].[dbo].[Membership Roster];
GO

-- Seed Contact_Infos
--   SELECT DISTINCT prevents duplicate address rows when household
--   members share an address.
INSERT INTO Contact_Infos (address, city, state, zipcode, email, phone)
SELECT DISTINCT
    [Address], [City], [State], [Zipcode], [Email_Address], [Phone]
FROM [HAM_Radio_LARC].[dbo].[Membership Roster];
GO

-- Seed Members
--   Correlated subqueries resolve each FK by matching the denormalized
--   staging column back to the newly created lookup tables.
--   TOP 1 is used defensively in case duplicates slipped through staging.
INSERT INTO Members (
    last_name, first_name, middle_initial, call_sign,
    license_id, membership_type_id, contact_info_id, membership_date_id
)
SELECT
    [Last_Name],
    [First_Name],
    [Middle_Initial],
    [Call_Sign],
    -- Resolve license FK
    (SELECT TOP 1 license_id
     FROM Licenses
     WHERE license_type_name = mr.[License_Class]),
    -- Resolve membership type FK
    (SELECT TOP 1 membership_type_id
     FROM Membership_Types
     WHERE membership_type_name = mr.[LARC_Membership_Type]),
    -- Resolve contact info FK (match on full address to avoid false joins)
    (SELECT TOP 1 contact_info_id
     FROM Contact_Infos
     WHERE address = mr.[Address]
       AND city    = mr.[City]
       AND state   = mr.[State]
       AND zipcode = mr.[Zipcode]),
    -- Resolve membership date FK
    (SELECT TOP 1 date_id
     FROM Membership_Dates
     WHERE expiration_date = mr.[Next_Membership_Expiration])
FROM [HAM_Radio_LARC].[dbo].[Membership Roster] mr;
GO

-- Seed Club_Officers from the staging column populated in Section 2
INSERT INTO Club_Officers (member_id, officer_role)
SELECT
    m.member_id,
    mr.Club_Officer
FROM [HAM_Radio_LARC].[dbo].[Membership Roster] mr
JOIN Members m
    ON m.first_name = mr.First_Name
   AND m.last_name  = mr.Last_Name
WHERE mr.Club_Officer IS NOT NULL;
GO

-- Seed Keys with sample facility key records
--   In production, this would be loaded from a key-tracking spreadsheet.
INSERT INTO Keys (key_number, key_issue_date, key_access_type)
VALUES
    ('K1001', GETDATE(), 'Front Door'),
    ('K1002', GETDATE(), 'Repeater Room'),
    ('K1003', GETDATE(), 'None');
GO

-- Seed Key_Holders: assign the first 3 members a key record each
--   CROSS JOIN + TOP 3 demonstrates the bridge table relationship;
--   real assignments would be data-driven.
INSERT INTO Key_Holders (member_id, key_id)
SELECT TOP 3
    m.member_id,
    k.key_id
FROM Members m
CROSS JOIN Keys k
WHERE k.key_access_type <> 'None';
GO

-- Seed Membership_Dues with a flat $50 payment per active member
--   Triggers in Section 6 will fire on these inserts and roll
--   expiration dates forward to 12/31 of the current year.
INSERT INTO Membership_Dues (member_id, payment_date, amount)
SELECT member_id, GETDATE(), 50.00
FROM Members;
GO


/* ============================================================
   SECTION 5 — COMPUTED / DERIVED COLUMNS

   These columns are added after initial data load so the
   UPDATE logic can reference already-populated rows.
   ============================================================ */

-- 5a. Volunteer status flag
--     Defaults to 'No'; updated manually by the membership chair
--     when a member signs up to volunteer at events.
ALTER TABLE Members
ADD member_vol_status VARCHAR(3) NOT NULL DEFAULT 'No'
    CHECK (member_vol_status IN ('Yes', 'No'));
GO

-- 5b. Membership badge tier
--     Tiered recognition based on tenure (years since begin_date).
--     Gold ≥ 10 yrs | Silver ≥ 5 yrs | Bronze ≥ 1 yr | New < 1 yr
--     Stored as a VARCHAR so it can be queried and displayed directly.
ALTER TABLE Members
ADD member_badge VARCHAR(10) NULL;
GO

UPDATE Members
SET member_badge =
    CASE
        WHEN DATEDIFF(YEAR, md.begin_date, GETDATE()) >= 10 THEN 'Gold'
        WHEN DATEDIFF(YEAR, md.begin_date, GETDATE()) >= 5  THEN 'Silver'
        WHEN DATEDIFF(YEAR, md.begin_date, GETDATE()) >= 1  THEN 'Bronze'
        ELSE 'New'
    END
FROM Members m
JOIN Membership_Dates md ON m.membership_date_id = md.date_id;
GO


/* ============================================================
   SECTION 6 — TRIGGER: AUTO-UPDATE EXPIRATION ON DUES PAYMENT

   Business rule: when a dues payment is recorded, the member's
   membership expiration date should automatically advance to
   December 31st of the current calendar year.

   AFTER INSERT fires once per batch; it reads from the logical
   'inserted' table (the set of newly inserted rows) to identify
   which members' expiration dates need updating.
   SET NOCOUNT ON suppresses row-count messages that could
   interfere with calling applications.
   ============================================================ */

CREATE TRIGGER trg_UpdateMembershipExpiration
ON Membership_Dues
AFTER INSERT
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE Membership_Dates
    SET expiration_date = DATEFROMPARTS(YEAR(GETDATE()), 12, 31)
    FROM Membership_Dates md
    INNER JOIN Members      m ON md.date_id   = m.membership_date_id
    INNER JOIN inserted     i ON m.member_id  = i.member_id;
    -- 'inserted' is the virtual table T-SQL provides inside triggers,
    -- containing every row that was part of the triggering INSERT.
END;
GO


/* ============================================================
   SECTION 7 — INDEXES

   Strategy: indexes are placed on columns that appear in WHERE
   clauses, JOIN conditions, and ORDER BY in expected queries.
   All indexes are NONCLUSTERED because the clustered index
   (on the PK) already covers point lookups by ID.
   ============================================================ */

-- Index: filter/sort members by membership type (e.g., active vs. silent key)
CREATE NONCLUSTERED INDEX IX_Members_MembershipType
ON Members (membership_type_id);
GO

-- Index: filter/sort members by badge tier (Gold / Silver / Bronze / New)
CREATE NONCLUSTERED INDEX IX_Members_Badge
ON Members (member_badge);
GO

-- Index: filter/sort members by volunteer status
CREATE NONCLUSTERED INDEX IX_Members_VolStatus
ON Members (member_vol_status);
GO

-- Index: license type name lookups (used in JOIN to Members)
CREATE NONCLUSTERED INDEX IX_Licenses_TypeName
ON Licenses (license_type_name);
GO

-- Index: key_id lookups in the bridge table (the FK side most often filtered)
CREATE NONCLUSTERED INDEX IX_KeyHolders_KeyID
ON Key_Holders (key_id);
GO


/* ============================================================
   SECTION 8 — VIEWS (Business-Facing Read Layer)

   Views abstract the JOIN logic from consumers (reports, apps)
   and provide a stable interface even if the underlying schema
   evolves. Using CREATE VIEW here also demonstrates DDL skills
   alongside DML.
   ============================================================ */

-- View: Club Officers with full member detail
--   Joins Members → Club_Officers → Contact_Infos so a single
--   SELECT gives everything needed for an officer roster report.
CREATE VIEW vw_Club_Officers AS
SELECT
    m.member_id,
    m.last_name,
    m.first_name,
    m.call_sign,
    co.officer_role,
    ci.email,
    ci.phone
FROM Members        m
JOIN Club_Officers  co ON m.member_id       = co.member_id
JOIN Contact_Infos  ci ON m.contact_info_id = ci.contact_info_id;
GO

-- View: Member Directory with license and membership status
--   Provides a flattened, human-readable directory suitable for
--   club newsletters or the website member portal.
CREATE VIEW vw_Member_Directory AS
SELECT
    m.member_id,
    m.last_name,
    m.first_name,
    m.call_sign,
    l.license_type_name,
    mt.membership_type_name,
    m.member_badge,
    m.member_vol_status,
    md.begin_date,
    md.expiration_date
FROM Members          m
JOIN Licenses         l  ON m.license_id         = l.license_id
JOIN Membership_Types mt ON m.membership_type_id  = mt.membership_type_id
JOIN Membership_Dates md ON m.membership_date_id  = md.date_id;
GO

-- View: Key Holder Roster
--   Lists every member who holds a physical club key, with
--   the key number and access type for security audits.
CREATE VIEW vw_Key_Holders AS
SELECT
    m.member_id,
    m.last_name,
    m.first_name,
    m.call_sign,
    k.key_number,
    k.key_access_type,
    k.key_issue_date
FROM Members     m
JOIN Key_Holders kh ON m.member_id = kh.member_id
JOIN Keys        k  ON kh.key_id   = k.key_id;
GO


/* ============================================================
   SECTION 9 — SAMPLE ANALYTICAL QUERIES

   These queries demonstrate practical business questions the
   club would ask of this database. Each includes a brief
   comment explaining its purpose and technique.
   ============================================================ */

-- Q1: All active members with a verified callsign
--     Filters out placeholder values ('no call', 'no-call', 'pending')
--     that were present in the original CSV data.
SELECT
    member_id,
    last_name,
    first_name,
    call_sign,
    member_badge
FROM Members
WHERE call_sign IS NOT NULL
  AND call_sign <> ''
  AND call_sign <> 'pending'
  AND call_sign NOT LIKE '%no call%'
  AND call_sign NOT LIKE '%no-call%'
ORDER BY last_name, first_name;
GO

-- Q2: Members awaiting a callsign (recently licensed, FCC pending)
SELECT
    member_id,
    last_name,
    first_name,
    call_sign
FROM Members
WHERE call_sign = 'pending'
ORDER BY last_name;
GO

-- Q3: All General-class license holders
--     JOIN demonstrates FK relationship between Members and Licenses.
SELECT
    m.member_id,
    m.last_name,
    m.first_name,
    m.call_sign,
    l.license_type_name
FROM Members  m
JOIN Licenses l ON m.license_id = l.license_id
WHERE l.license_type_name = 'General'
ORDER BY m.last_name;
GO

-- Q4: Member count by license class
--     Aggregate query useful for reporting club demographics.
SELECT
    l.license_type_name,
    COUNT(m.member_id) AS member_count
FROM Members  m
JOIN Licenses l ON m.license_id = l.license_id
GROUP BY l.license_type_name
ORDER BY member_count DESC;
GO

-- Q5: Badge tier distribution
--     Shows how tenured the membership is at a glance.
SELECT
    member_badge,
    COUNT(*) AS member_count
FROM Members
GROUP BY member_badge
ORDER BY
    CASE member_badge
        WHEN 'Gold'   THEN 1
        WHEN 'Silver' THEN 2
        WHEN 'Bronze' THEN 3
        ELSE 4
    END;
GO

-- Q6: Members whose membership expires within the next 30 days
--     Useful for generating renewal reminder emails.
SELECT
    m.member_id,
    m.last_name,
    m.first_name,
    m.call_sign,
    ci.email,
    md.expiration_date
FROM Members          m
JOIN Membership_Dates md ON m.membership_date_id  = md.date_id
JOIN Contact_Infos    ci ON m.contact_info_id      = ci.contact_info_id
WHERE md.expiration_date BETWEEN GETDATE() AND DATEADD(DAY, 30, GETDATE())
ORDER BY md.expiration_date;
GO

-- Q7: Active volunteers available for events
SELECT
    m.member_id,
    m.last_name,
    m.first_name,
    m.call_sign,
    ci.phone,
    ci.email
FROM Members       m
JOIN Contact_Infos ci ON m.contact_info_id = ci.contact_info_id
WHERE m.member_vol_status = 'Yes'
ORDER BY m.last_name;
GO

-- Q8: Total dues collected by month (payment ledger summary)
SELECT
    YEAR(payment_date)  AS payment_year,
    MONTH(payment_date) AS payment_month,
    COUNT(*)            AS payments_received,
    SUM(amount)         AS total_collected
FROM Membership_Dues
GROUP BY YEAR(payment_date), MONTH(payment_date)
ORDER BY payment_year, payment_month;
GO

-- Q9: Verify schema — confirm INFORMATION_SCHEMA for all expected views
SELECT TABLE_NAME, TABLE_TYPE
FROM INFORMATION_SCHEMA.VIEWS
WHERE TABLE_NAME IN ('vw_Club_Officers', 'vw_Member_Directory', 'vw_Key_Holders');
GO

-- Q10: Full data verification — spot-check all tables
SELECT 'Members'          AS tbl, COUNT(*) AS row_count FROM Members
UNION ALL
SELECT 'Licenses',                COUNT(*)               FROM Licenses
UNION ALL
SELECT 'Membership_Types',        COUNT(*)               FROM Membership_Types
UNION ALL
SELECT 'Membership_Dates',        COUNT(*)               FROM Membership_Dates
UNION ALL
SELECT 'Contact_Infos',           COUNT(*)               FROM Contact_Infos
UNION ALL
SELECT 'Club_Officers',           COUNT(*)               FROM Club_Officers
UNION ALL
SELECT 'Membership_Dues',         COUNT(*)               FROM Membership_Dues
UNION ALL
SELECT 'Keys',                    COUNT(*)               FROM Keys
UNION ALL
SELECT 'Key_Holders',             COUNT(*)               FROM Key_Holders;
GO


/* ============================================================
   SECTION 10 — SCHEMA DOWN (TEARDOWN SCRIPT)

   Drops are ordered by dependency:
     1. Views (no dependents)
     2. Trigger (attached to Membership_Dues)
     3. Child / bridge tables (hold FKs pointing to parents)
     4. Parent tables (lookup / dimension tables)
     5. Staging table (raw import)
     6. Database itself

   IF EXISTS guards make this script safe to re-run
   (idempotent teardown).
   ============================================================ */

USE HAM_Radio_LARC;
GO

-- Drop views
DROP VIEW IF EXISTS vw_Club_Officers;
DROP VIEW IF EXISTS vw_Member_Directory;
DROP VIEW IF EXISTS vw_Key_Holders;
GO

-- Drop trigger before dropping its parent table
DROP TRIGGER IF EXISTS trg_UpdateMembershipExpiration;
GO

-- Drop child / bridge tables (depend on Members)
DROP TABLE IF EXISTS Club_Officers;
DROP TABLE IF EXISTS Membership_Dues;
DROP TABLE IF EXISTS Key_Holders;
GO

-- Drop Keys (no longer referenced)
DROP TABLE IF EXISTS Keys;
GO

-- Drop Members (references all lookup tables)
DROP TABLE IF EXISTS Members;
GO

-- Drop lookup / dimension tables
DROP TABLE IF EXISTS Licenses;
DROP TABLE IF EXISTS Membership_Types;
DROP TABLE IF EXISTS Membership_Dates;
DROP TABLE IF EXISTS Contact_Infos;
GO

-- Drop staging table
DROP TABLE IF EXISTS [dbo].[Membership Roster];
GO

-- Force single-user mode before dropping the database to prevent
-- active connection errors.
ALTER DATABASE HAM_Radio_LARC SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
GO

DROP DATABASE HAM_Radio_LARC;
GO

/* ============================================================
   END OF SCRIPT
   ============================================================ */
