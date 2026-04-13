"""enable pgvector extension

Revision ID: e1f2a3b4c5d6
Revises: 3f8e9a0b1c2d
Create Date: 2026-04-10 00:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'e1f2a3b4c5d6'
down_revision: Union[str, None] = 'a9c9ea721187'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Enable pgvector extension using a SAVEPOINT so that failure (e.g. the
    # extension package is not installed on this PostgreSQL) does not abort
    # the entire Alembic transaction.
    conn = op.get_bind()
    conn.execute(sa.text("SAVEPOINT pgvector_ext"))
    try:
        conn.execute(sa.text("CREATE EXTENSION IF NOT EXISTS vector"))
        conn.execute(sa.text("RELEASE SAVEPOINT pgvector_ext"))
    except Exception:
        conn.execute(sa.text("ROLLBACK TO SAVEPOINT pgvector_ext"))
        # pgvector package not available on this host — PGVectorStore will
        # attempt CREATE EXTENSION at runtime and log a warning if it fails.


def downgrade() -> None:
    # Never drop the vector extension — it would destroy all embedding data.
    pass
