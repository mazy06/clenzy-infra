-- Script to add the 'deferred_payment' column to the 'users' table
ALTER TABLE users ADD COLUMN deferred_payment BOOLEAN DEFAULT FALSE;