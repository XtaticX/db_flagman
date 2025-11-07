-- Включаем расширения
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ENUM-типы
CREATE TYPE user_role AS ENUM ('OWNER', 'ADMIN', 'USER');
CREATE TYPE warehouse_type AS ENUM ('MAIN', 'RETAIL', 'TRANSIT', 'QUARANTINE');
CREATE TYPE document_status AS ENUM ('DRAFT', 'PENDING', 'APPROVED', 'COMPLETED', 'CANCELLED');
CREATE TYPE movement_type AS ENUM ('INCOME', 'OUTCOME', 'ADJUSTMENT');
CREATE TYPE adjustment_reason AS ENUM ('INVENTORY_DISCREPANCY', 'DAMAGED', 'LOST', 'FOUND');
CREATE TYPE device_type AS ENUM ('SCANNER', 'MOBILE', 'TABLET', 'TSD', 'PRINTER');
CREATE TYPE sync_type AS ENUM ('FULL', 'INCREMENTAL', 'UPLOAD');
CREATE TYPE log_level AS ENUM ('ERROR', 'WARN', 'INFO', 'DEBUG');
CREATE TYPE report_type AS ENUM ('MOVEMENT', 'STOCK', 'SCANNING');

-- 1. Пользователи и авторизация
CREATE TABLE users (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    email TEXT NOT NULL UNIQUE,
    password_hash TEXT NOT NULL,
    full_name TEXT NOT NULL,
    phone TEXT,
    timezone TEXT DEFAULT 'UTC',
    language TEXT DEFAULT 'en',
    is_active BOOLEAN DEFAULT TRUE,
    email_verified BOOLEAN DEFAULT FALSE,
    verification_code TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE user_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    token TEXT NOT NULL UNIQUE,
    device_info JSONB,
    expires_at TIMESTAMPTZ NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Индекс по истекающим сессиям
CREATE INDEX idx_user_sessions_expires ON user_sessions(expires_at);

-- 2. Организации
CREATE TABLE organizations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    name TEXT NOT NULL,
    legal_name TEXT,
    description TEXT,
    tax_id TEXT,
    address JSONB,
    settings JSONB DEFAULT '{}',
    qr_code TEXT,
    qr_code_expires_at TIMESTAMPTZ,
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE organization_members (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    role user_role NOT NULL,
    permissions JSONB DEFAULT '{}',
    joined_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (organization_id, user_id)
);

-- 3. Склады
CREATE TABLE warehouses (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    code TEXT NOT NULL,
    type warehouse_type NOT NULL,
    address JSONB,
    contact_person JSONB,
    settings JSONB DEFAULT '{}',
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (organization_id, code)
);

CREATE TABLE warehouse_zones (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    code TEXT NOT NULL,
    temperature_zone TEXT,
    description TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (warehouse_id, code)
);

-- 4. Категории товаров
CREATE TABLE product_categories (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    parent_id UUID REFERENCES product_categories(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    description TEXT,
    sort_order INTEGER DEFAULT 0,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 5. Номенклатура (товары)
CREATE TABLE products (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    category_id UUID REFERENCES product_categories(id) ON DELETE SET NULL,
    name TEXT NOT NULL,
    sku TEXT NOT NULL,
    barcode TEXT,
    barcode_type TEXT,
    brand TEXT,
    model TEXT,
    description TEXT,
    unit TEXT NOT NULL,
    weight NUMERIC(10,3),
    dimensions JSONB, -- {length, width, height}
    pricing JSONB,   -- {costPrice, sellingPrice, currency}
    inventory_settings JSONB, -- {minStock, maxStock, reorderPoint}
    attributes JSONB DEFAULT '{}',
    images TEXT[],
    is_active BOOLEAN DEFAULT TRUE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (organization_id, sku),
    UNIQUE (organization_id, barcode)
);

-- 6. Документы
CREATE TABLE documents (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    type TEXT NOT NULL, -- e.g., 'TTN', 'INVENTORY'
    number TEXT NOT NULL,
    status document_status NOT NULL DEFAULT 'DRAFT',
    warehouse_from_id UUID REFERENCES warehouses(id) ON DELETE SET NULL,
    warehouse_to_id UUID REFERENCES warehouses(id) ON DELETE SET NULL,
    sender_info JSONB,
    receiver_info JSONB,
    transport_info JSONB,
    reason TEXT,
    scheduled_date DATE,
    assigned_to UUID[],
    settings JSONB DEFAULT '{}',
    notes TEXT,
    attachments TEXT[],
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (organization_id, number)
);

CREATE TABLE document_items (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    document_id UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    quantity NUMERIC(15,3) NOT NULL,
    unit TEXT NOT NULL,
    price NUMERIC(15,2),
    vat_rate NUMERIC(5,2),
    batch_number TEXT,
    serial_numbers TEXT[],
    location TEXT,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE document_status_history (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    document_id UUID NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    old_status document_status,
    new_status document_status NOT NULL,
    comment TEXT,
    changed_by UUID REFERENCES users(id) ON DELETE SET NULL,
    changed_at TIMESTAMPTZ DEFAULT NOW()
);

-- 7. Остатки и движения
CREATE TABLE stock (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
    quantity NUMERIC(15,3) NOT NULL DEFAULT 0,
    reserved_quantity NUMERIC(15,3) NOT NULL DEFAULT 0,
    batch_number TEXT,
    location TEXT,
    last_updated TIMESTAMPTZ DEFAULT NOW(),
    UNIQUE (warehouse_id, product_id, batch_number, location)
);

CREATE TABLE stock_movements (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    product_id UUID NOT NULL REFERENCES products(id) ON DELETE RESTRICT,
    document_id UUID REFERENCES documents(id) ON DELETE SET NULL,
    movement_type movement_type NOT NULL,
    quantity_before NUMERIC(15,3) NOT NULL,
    quantity_change NUMERIC(15,3) NOT NULL,
    quantity_after NUMERIC(15,3) NOT NULL,
    batch_number TEXT,
    reason TEXT,
    comment TEXT,
    created_by UUID REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE stock_adjustments (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    warehouse_id UUID NOT NULL REFERENCES warehouses(id) ON DELETE CASCADE,
    reason adjustment_reason NOT NULL,
    items JSONB NOT NULL, -- array of {productId, quantity, newQuantity, comment}
    created_by UUID NOT NULL REFERENCES users(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 8. Устройства
CREATE TABLE devices (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    device_id TEXT NOT NULL UNIQUE,
    name TEXT NOT NULL,
    type device_type NOT NULL,
    model TEXT,
    serial_number TEXT,
    firmware_version TEXT,
    capabilities JSONB DEFAULT '{}',
    settings JSONB DEFAULT '{}',
    location JSONB, -- {warehouseId, zone, description}
    last_seen TIMESTAMPTZ,
    is_online BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 9. Работа со сканированием
CREATE TYPE scan_mode AS ENUM ('INVENTORY', 'RECEIVING', 'PICKING', 'ADJUSTMENT');
CREATE TYPE scan_session_status AS ENUM ('ACTIVE', 'COMPLETED', 'CANCELLED');

CREATE TABLE scan_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    document_id UUID REFERENCES documents(id) ON DELETE SET NULL,
    device_id UUID REFERENCES devices(id) ON DELETE SET NULL,
    mode scan_mode NOT NULL,
    location TEXT,
    status scan_session_status NOT NULL DEFAULT 'ACTIVE',
    started_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ,
    session_data JSONB DEFAULT '{}'
);

CREATE TABLE scan_operations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    session_id UUID NOT NULL REFERENCES scan_sessions(id) ON DELETE CASCADE,
    product_id UUID REFERENCES products(id) ON DELETE SET NULL,
    barcode TEXT NOT NULL,
    quantity NUMERIC(15,3) NOT NULL DEFAULT 1,
    location TEXT,
    batch_number TEXT,
    serial_numbers TEXT[],
    metadata JSONB DEFAULT '{}',
    scanned_at TIMESTAMPTZ DEFAULT NOW()
);

-- 10. Синхронизация
CREATE TABLE sync_sessions (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    device_id UUID REFERENCES devices(id) ON DELETE SET NULL,
    sync_type sync_type NOT NULL,
    last_sync_date TIMESTAMPTZ,
    include_tables TEXT[],
    status TEXT NOT NULL, -- IN_PROGRESS, COMPLETED, FAILED
    records_synced INTEGER DEFAULT 0,
    started_at TIMESTAMPTZ DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

CREATE TABLE offline_operations (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    device_id UUID REFERENCES devices(id) ON DELETE SET NULL,
    session_id TEXT NOT NULL,
    operation_type TEXT NOT NULL,
    operation_data JSONB NOT NULL,
    timestamp TIMESTAMPTZ NOT NULL,
    is_synced BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Индекс для поиска несинхронизированных операций
CREATE INDEX idx_offline_ops_unsynced ON offline_operations(is_synced) WHERE NOT is_synced;

-- 11. Системные таблицы
CREATE TABLE system_logs (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID REFERENCES organizations(id) ON DELETE CASCADE,
    level log_level NOT NULL,
    message TEXT NOT NULL,
    context JSONB DEFAULT '{}',
    user_id UUID REFERENCES users(id) ON DELETE SET NULL,
    device_id UUID REFERENCES devices(id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE TABLE reports (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
    type report_type NOT NULL,
    name TEXT NOT NULL,
    parameters JSONB DEFAULT '{}',
    generated_by UUID REFERENCES users(id) ON DELETE SET NULL,
    file_path TEXT NOT NULL,
    created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Индексы для ускорения поиска
CREATE INDEX idx_documents_org_status ON documents(organization_id, status);
CREATE INDEX idx_stock_warehouse_product ON stock(warehouse_id, product_id);
CREATE INDEX idx_scan_sessions_device ON scan_sessions(device_id);
CREATE INDEX idx_users_email ON users(email);
CREATE INDEX idx_products_org_sku ON products(organization_id, sku);
