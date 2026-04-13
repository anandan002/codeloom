"""enable AGE extension and add age_graph_status to projects

Revision ID: 3f8e9a0b1c2d
Revises: 2e7dbe92a6af
Create Date: 2026-03-13 10:00:00.000000

"""
from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = '3f8e9a0b1c2d'
down_revision: Union[str, None] = '2e7dbe92a6af'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def upgrade() -> None:
    # Enable Apache AGE extension.
    # Uses a SAVEPOINT so failure (AGE not installed on this PostgreSQL) does not
    # abort the transaction — the age_graph_status column is always added regardless.
    conn = op.get_bind()
    conn.execute(sa.text("SAVEPOINT age_ext"))
    try:
        conn.execute(sa.text("CREATE EXTENSION IF NOT EXISTS age"))
        conn.execute(sa.text("RELEASE SAVEPOINT age_ext"))
    except Exception:
        conn.execute(sa.text("ROLLBACK TO SAVEPOINT age_ext"))
        # AGE not available on this host; graph features will be disabled at runtime.

    # Add graph sync status to projects (always runs, AGE or not)
    op.add_column(
        'projects',
        sa.Column('age_graph_status', sa.String(20), server_default='pending'),
    )


def downgrade() -> None:
    op.drop_column('projects', 'age_graph_status')
