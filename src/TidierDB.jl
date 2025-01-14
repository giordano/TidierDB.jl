module TidierDB

using LibPQ
using DataFrames
using MacroTools
using Chain
using SQLite
using Reexport
using DuckDB
using MySQL
using ODBC 
import ClickHouse
using Arrow
using AWS
using JSON3
using GoogleCloud
using HTTP
using JSON3
using GZip

@reexport using DataFrames: DataFrame
@reexport using Chain
@reexport using DuckDB
import DuckDB: open as duckdb_open
import DuckDB: connect as duckdb_connect
#using TidierDB

 export db_table, set_sql_mode, @arrange, @group_by, @filter, @select, @mutate, @summarize, @summarise, 
 @distinct, @left_join, @right_join, @inner_join, @count, @window_order, @window_frame, @show_query, @collect, @slice_max, 
 @slice_min, @slice_sample, @rename, copy_to, duckdb_open, duckdb_connect, @semi_join, @full_join, 
 @anti_join, connect, from_query, @interpolate, add_interp_parameter!, update_con

include("docstrings.jl")
include("structs.jl")
include("db_parsing.jl")
include("TBD_macros.jl")
include("parsing_sqlite.jl")
include("parsing_duckdb.jl")
include("parsing_postgres.jl")
include("parsing_mysql.jl")
include("parsing_mssql.jl")
include("parsing_clickhouse.jl")
include("parsing_athena.jl")
include("parsing_gbq.jl")
include("parsing_snowflake.jl")
include("parsing_oracle.jl")
include("parsing_databricks.jl")
include("joins_sq.jl")
include("slices_sq.jl")


current_sql_mode = Ref(:duckdb)

# Function to switch modes
function set_sql_mode(mode::Symbol)
    current_sql_mode[] = mode
end

# Unified expr_to_sql function to use right mode
function expr_to_sql(expr, sq; from_summarize::Bool = false)
    if current_sql_mode[] == :lite
        return expr_to_sql_lite(expr, sq, from_summarize=from_summarize)
    elseif current_sql_mode[] == :postgres
        return expr_to_sql_postgres(expr, sq; from_summarize=from_summarize)
    elseif current_sql_mode[] == :duckdb
        return expr_to_sql_duckdb(expr, sq; from_summarize=from_summarize)
    elseif current_sql_mode[] == :mysql
        return expr_to_sql_mysql(expr, sq; from_summarize=from_summarize)
    elseif current_sql_mode[] == :mssql
        return expr_to_sql_mssql(expr, sq; from_summarize=from_summarize)
    elseif current_sql_mode[] == :clickhouse
        return expr_to_sql_clickhouse(expr, sq; from_summarize=from_summarize)
    elseif current_sql_mode[] == :athena
        return expr_to_sql_trino(expr, sq; from_summarize=from_summarize)
    elseif current_sql_mode[] == :gbq
        return expr_to_sql_gbq(expr, sq; from_summarize=from_summarize)
    elseif current_sql_mode[] == :oracle
        return expr_to_sql_oracle(expr, sq; from_summarize=from_summarize)
    elseif current_sql_mode[] == :snowflake
        return expr_to_sql_snowflake(expr, sq; from_summarize=from_summarize)
    else
        error("Unsupported SQL mode: $(current_sql_mode[])")
    end
end



function finalize_ctes(ctes::Vector{CTE})
    if isempty(ctes)
        return ""
    end

    cte_strings = String[]
    for cte in ctes
        cte_str = string(
            cte.name, " AS (SELECT ", cte.select, 
            occursin(" FROM ", cte.select) ? "" : " FROM " * cte.from, 
            (!isempty(cte.where) ? " WHERE " * cte.where : ""), 
            (!isempty(cte.groupBy) ? " GROUP BY " * cte.groupBy : ""), 
            (!isempty(cte.having) ? " HAVING " * cte.having : ""), 
            ")"
        )
        push!(cte_strings, cte_str)
    end

    return "WITH " * join(cte_strings, ", ") * " "
end

function finalize_query(sqlquery::SQLQuery)
    cte_part = finalize_ctes(sqlquery.ctes)

    select_already_present = occursin(r"^SELECT\s+", uppercase(sqlquery.select))
    select_part = if sqlquery.distinct && !select_already_present
        "SELECT DISTINCT " * (isempty(sqlquery.select) ? "*" : sqlquery.select)
    elseif !select_already_present
        "SELECT " * (isempty(sqlquery.select) ? "*" : sqlquery.select)
    else
        sqlquery.select
    end

    # Initialize query_parts with the CTE part
    query_parts = [cte_part]

    # Since sq.from has been updated to reference a CTE, adjust the FROM clause accordingly
    if !isempty(sqlquery.ctes)
        # If CTEs are defined, FROM clause should reference the latest CTE (already updated in sq.from)
        push!(query_parts, select_part, "FROM " * sqlquery.from)
    else
        # If no CTEs are defined, use the original table name in sq.from
        push!(query_parts, select_part, "FROM " * sqlquery.from)
    end

    # Append other clauses if present
    if !isempty(sqlquery.where) push!(query_parts, " " * sqlquery.where) end
    if !isempty(sqlquery.groupBy) push!(query_parts, "" * sqlquery.groupBy) end
    if !isempty(sqlquery.having) push!(query_parts, " " * sqlquery.having) end
    if !isempty(sqlquery.orderBy) push!(query_parts, " " * sqlquery.orderBy) end

    complete_query = join(filter(!isempty, query_parts), " ")
    complete_query = replace(complete_query, "&&" => " AND ", "||" => " OR ",
     "FROM )" => ")" ,  "SELECT SELECT " => "SELECT ", "SELECT  SELECT " => "SELECT ", "DISTINCT SELECT " => "DISTINCT ", 
     "SELECT SELECT SELECT " => "SELECT ", "PARTITION BY GROUP BY" => "PARTITION BY", "GROUP BY GROUP BY" => "GROUP BY", "HAVING HAVING" => "HAVING", )

    if current_sql_mode[] == :postgres || current_sql_mode[] == :duckdb || current_sql_mode[] == :mysql || current_sql_mode[] == :mssql || current_sql_mode[] == :clickhouse || current_sql_mode[] == :athena || current_sql_mode[] == :gbq || current_sql_mode[] == :oracle  || current_sql_mode[] == :snowflake
        complete_query = replace(complete_query, "\"" => "'", "==" => "=")
    end

    return complete_query
end


function get_table_metadata(db::SQLite.DB, table_name::String)
    query = "PRAGMA table_info($table_name);"
    result = SQLite.DBInterface.execute(db, query) |> DataFrame
    result[!, :current_selxn] .= 1
    resize!(result.current_selxn, nrow(result))
    result[!, :table_name] .= table_name
    # Adjust the select statement to include the new table_name column
    return DataFrames.select(result, 2 => :name, 3 => :type, :current_selxn, :table_name)
end

function get_table_metadata(conn::LibPQ.Connection, table_name::String)
    query = """
    SELECT column_name, data_type
    FROM information_schema.columns
    WHERE table_name = '$table_name'
    ORDER BY ordinal_position;
    """
    result = LibPQ.execute(conn, query) |> DataFrame
    result[!, :current_selxn] .= 1
    result[!, :table_name] .= table_name
    # Adjust the select statement to include the new table_name column
    return select(result, 1 => :name, 2 => :type, :current_selxn, :table_name)
end


# DuckDB
function get_table_metadata(conn::DuckDB.DB, table_name::String)
    query = 
        """
        DESCRIBE SELECT * FROM $(table_name) LIMIT 0
        """
    result = DuckDB.execute(conn, query) |> DataFrame
    result[!, :current_selxn] .= 1
    table_name = if occursin(r"[:/]", table_name)
         split(basename(table_name), '.')[1]
        #"'$table_name'"
    else
        table_name
    end
    result[!, :table_name] .= table_name
    # Adjust the select statement to include the new table_name column
    return select(result, 1 => :name, 2 => :type, :current_selxn, :table_name)
end

# MySQL
function get_table_metadata(conn::MySQL.Connection, table_name::String)
    # Query to get column names and types from INFORMATION_SCHEMA
    query = """
    SELECT column_name, data_type
    FROM information_schema.columns
    WHERE table_name = '$table_name'
    AND TABLE_SCHEMA = '$(conn.db)'
    ORDER BY ordinal_position;
    """

    result = DBInterface.execute(conn, query) |> DataFrame
    result[!, 2] = map(x -> String(x), result[!, 2])
    result[!, :current_selxn] .= 1
    result[!, :table_name] .= table_name
    # Adjust the select statement to include the new table_name column
    return DataFrames.select(result, :1 => :name, 2 => :type, :current_selxn, :table_name)
end

# MSSQL
function get_table_metadata(conn::ODBC.Connection, table_name::String)
    if current_sql_mode[] == :oracle
        table_name = uppercase(table_name)
        query = """
        SELECT column_name, data_type
        FROM all_tab_columns
        WHERE table_name = '$table_name'
        ORDER BY column_id
        """
    else
        query = """
        SELECT column_name, data_type
        FROM information_schema.columns
        WHERE table_name = '$table_name'
        ORDER BY ordinal_position;
        """
    end

    result = DBInterface.execute(conn, query) |> DataFrame
    result[!, :current_selxn] .= 1
    result[!, :table_name] .= table_name
    # Adjust the select statement to include the new table_name column
    return select(result, :column_name => :name, :data_type => :type, :current_selxn, :table_name)
end

 # ClickHouse
function get_table_metadata(conn::ClickHouse.ClickHouseSock, table_name::String)
    # Query to get column names and types from INFORMATION_SCHEMA
    query = """
    SELECT
        name AS column_name,
        type AS data_type
    FROM system.columns
    WHERE table = '$table_name' AND database = 'default'
    """
    result = ClickHouse.select_df(conn,query)

    result[!, :current_selxn] .= 1
    result[!, :table_name] .= table_name
    # Adjust the select statement to include the new table_name column
    return select(result, 1 => :name, 2 => :type, :current_selxn, :table_name)
end

"""
$docstring_db_table
"""
function db_table(db, table, athena_params::Any=nothing; iceberg::Bool=false, delta::Bool=false)
    table_name = string(table)
    
    if current_sql_mode[] == :lite
        metadata = get_table_metadata(db, table_name)
    elseif current_sql_mode[] == :postgres ||current_sql_mode[] ==  :duckdb || current_sql_mode[] ==  :mysql || current_sql_mode[] ==  :mssql || current_sql_mode[] ==  :clickhouse || current_sql_mode[] ==  :gbq ||current_sql_mode[] ==  :oracle
        if iceberg
            DBInterface.execute(db, "INSTALL iceberg;")
            DBInterface.execute(db, "LOAD iceberg;")
            table_name2 = "iceberg_scan('$table_name', allow_moved_paths = true)"
            metadata = get_table_metadata(db, table_name2)
        elseif delta
            DuckDB.execute(db, "INSTALL delta;")
            DuckDB.execute(db, "LOAD delta;")
            table_name2 = "delta_scan('$table_name')"
           # println(table_name2)
            metadata = get_table_metadata(db, table_name2)
        elseif occursin(r"[:/]", table_name) 
            table_name2 = "'$table_name'"
            metadata = get_table_metadata(db, table_name2)
        else
            metadata = get_table_metadata(db, table_name)
        end
    elseif current_sql_mode[] == :athena
        metadata = get_table_metadata_athena(db, table_name, athena_params)
    elseif current_sql_mode[] == :snowflake
        metadata = get_table_metadata(db, table_name)
    else
        error("Unsupported SQL mode: $(current_sql_mode[])")
    end

    formatted_table_name = if current_sql_mode[] == :snowflake
        "$(db.database).$(db.schema).$table_name"
    elseif db isa DatabricksConnection
        "$(db.database).$(db.schema).$table_name"
    elseif iceberg
        "iceberg_scan('$table_name', allow_moved_paths = true)"
    elseif delta
        "delta_scan('$table_name')"
    elseif occursin(r"[:/]", table_name) && !(iceberg || delta)
        "'$table_name'"
    else
        table_name
    end
    
    return SQLQuery(from=formatted_table_name, metadata=metadata, db=db, athena_params=athena_params)
end

"""
$docstring_copy_to
"""
function copy_to(conn, df_or_path::Union{DataFrame, AbstractString}, name::String)
    # Check if the input is a DataFrame
    if isa(df_or_path, DataFrame)
        if current_sql_mode[] == :duckdb
            DuckDB.register_data_frame(conn, df_or_path, name)
        elseif current_sql_mode[] == :lite
            SQLite.load!(df_or_path, conn, name)
        elseif current_sql_mode[] == :mysql
            MySQL.load(df_or_path, conn, name)
        else
            error("Unsupported SQL mode: $(current_sql_mode[])")
        end
    # If the input is not a DataFrame, treat it as a file path
    elseif isa(df_or_path, AbstractString)
        if current_sql_mode[] != :duckdb
            error("Direct file loading is only supported for DuckDB in this implementation.")
        end
        # Determine the file type based on the extension
        if startswith(df_or_path, "http")
            # Install and load the httpfs extension if the path is a URL
            DuckDB.execute(conn, "INSTALL httpfs;")
            DuckDB.execute(conn, "LOAD httpfs;")
        end
        if occursin(r"\.csv$", df_or_path)
            # Construct and execute a SQL command for loading a CSV file
            sql_command = "CREATE TABLE $name AS SELECT * FROM '$df_or_path';"
            DuckDB.execute(conn, sql_command)
        elseif occursin(r"\.parquet$", df_or_path)
            # Construct and execute a SQL command for loading a Parquet file
            sql_command = "CREATE TABLE $name AS SELECT * FROM '$df_or_path';"
            DuckDB.execute(conn, sql_command)
        elseif occursin(r"\.arrow$", df_or_path)
            # Construct and execute a SQL command for loading a CSV file
            arrow_table = Arrow.Table(df_or_path)
            DuckDB.register_table(conn, arrow_table, name)
        elseif occursin(r"\.json$", df_or_path)
            # For Arrow files, read the file into a DataFrame and then insert
            sql_command = "CREATE TABLE $name AS SELECT * FROM read_json('$df_or_path');"
            DuckDB.execute(conn, "INSTALL json;")
            DuckDB.execute(conn, "LOAD json;")
            DuckDB.execute(conn, sql_command)
        else
            error("Unsupported file type for: $df_or_path")
        end
    else
        error("Unsupported type for df_or_path: Must be DataFrame or file path string.")
    end
end


"""
$docstring_connect
"""
function connect(backend::Symbol; kwargs...)
    if backend == :MySQL || backend == :mysql 
        set_sql_mode(:mysql)

        # Required parameters by MySQL.jl: host and user
        host = get(kwargs, :host, "localhost")
        user = get(kwargs, :user, "")          
        password = get(kwargs, :password, "")  
        # Extract other optional parameters
        db = get(kwargs, :db, nothing)  
        port = get(kwargs, :port, nothing)     
        return DBInterface.connect(MySQL.Connection, host, user, password; db=db, port=port)
    elseif backend == :Postgres ||  backend == :postgres 
        set_sql_mode(:postgres)
        # Construct a connection string from kwargs for LibPQ
        conn_str = join(["$(k)=$(v)" for (k, v) in kwargs], " ")
        return LibPQ.Connection(conn_str)
    elseif backend == :MsSQL || backend == :mssql 
        set_sql_mode(:mssql)
        # Construct a connection string for ODBC if required for MsSQL
        conn_str = join(["$(k)=$(v)" for (k, v) in kwargs], ";")
        return ODBC.Connection(conn_str)
    elseif backend == :Clickhouse || backend == :clickhouse 
        set_sql_mode(:clickhouse)
        if haskey(kwargs, :host) && haskey(kwargs, :port)
            return ClickHouse.connect(kwargs[:host], kwargs[:port]; (k => v for (k, v) in kwargs if k ∉ [:host, :port])...)
        else
            throw(ArgumentError("Missing required positional arguments 'host' and 'port' for ClickHouse."))
        end
    elseif backend == :SQLite || backend == :lite
        db_path = get(kwargs, :db, ":memory:") 
        set_sql_mode(:lite)
        return SQLite.DB(db_path)
    elseif backend == :DuckDB || backend == :duckdb
        set_sql_mode(:duckdb)
        db = DBInterface.connect(DuckDB.DB, ":memory:")
        DBInterface.execute(db, "SET autoinstall_known_extensions=1;")
        DBInterface.execute(db, "SET autoload_known_extensions=1;")
    
        # Install and load the httpfs extension
        DBInterface.execute(db, "INSTALL httpfs;")
        DBInterface.execute(db, "LOAD httpfs;")
        return db
    else
        throw(ArgumentError("Unsupported backend: $backend"))
    end
end

function connect(backend::Symbol, identifier::String, auth_token::String, database::String, schema::String, warehouse::String)
    if backend == :snowflake
        # Snowflake specific settings
        set_sql_mode(:snowflake)
        api_url = "https://$identifier.snowflakecomputing.com/api/v2/statements"
        return SnowflakeConnection(identifier, auth_token, database, schema, warehouse, api_url)
    elseif backend == :databricks
        # Databricks specific settings
        # Remove any leading slash from workspace_id
        identifier = lstrip(identifier, '/')
        api_url = "https://$(identifier).cloud.databricks.com/api/2.0/sql/statements"
        return DatabricksConnection(identifier, auth_token, database, schema, warehouse, api_url)
    else
        error("Unsupported backend type: $backend")
    end
end

function connect(backend_type::Symbol, db_type::Symbol; access_key::String="", secret_key::String="", aws_access_key_id::String="", aws_secret_access_key::String="", aws_region::String="")
    # Connect to the DuckDB database
    mem = DuckDB.open(":memory:")
    db = DuckDB.connect(mem)

    # Enable auto-install and auto-load of known extensions
    DBInterface.execute(db, "SET autoinstall_known_extensions=1;")
    DBInterface.execute(db, "SET autoload_known_extensions=1;")

    # Install and load the httpfs extension
    DBInterface.execute(db, "INSTALL httpfs;")
    DBInterface.execute(db, "LOAD httpfs;")

    if db_type == :gbq
        DuckDB.execute(db, """
        CREATE SECRET (
            TYPE GCS,
            KEY_ID '$access_key',
            SECRET '$secret_key'
        );
        """)
    elseif db_type == :aws
        DBInterface.execute(db, "SET s3_region='$aws_region';")
        DBInterface.execute(db, "SET s3_access_key_id='$aws_access_key_id';")
        DBInterface.execute(db, "SET s3_secret_access_key='$aws_secret_access_key';")
    end

    return db
end

function connect(symbol, token::String)
    if token == "md:"
        return DBInterface.connect(DuckDB.DB, "md:")
    else
        return DBInterface.connect(DuckDB.DB, "md:$token")
    end 
end

end
