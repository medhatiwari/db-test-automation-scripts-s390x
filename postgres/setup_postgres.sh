#!/bin/bash

# Variables for logging
LOG_FILE="$(pwd)/script_log_$(date +"%Y%m%d%H%M").log"
touch "$LOG_FILE"  # Ensure the log file is created
exec > >(tee -i "$LOG_FILE") 2>&1  # Redirect all output to both console and log file

ERROR_OCCURRED=0  

# Detect OS type
detect_os() {
    if [ -f /etc/redhat-release ]; then
        echo "RHEL/CentOS detected."
        OS="rhel"
    elif [ -f /etc/debian_version ]; then
        echo "Debian/Ubuntu detected."
        OS="debian"
    else
        echo "Unsupported OS."
        ERROR_OCCURRED=1
    fi
}

# User input for PostgreSQL and .NET SDK details
get_user_inputs() {
    read -p "Enter the PostgreSQL database name: " DB_NAME
    read -p "Enter the PostgreSQL username: " DB_USER
    read -sp "Enter the PostgreSQL password: " DB_PASSWORD
    echo
    read -p "Enter the .NET SDK version (leave blank to use the system version): " DOTNET_VERSION
    read -p "Enter the .NET SDK download URL (leave blank to use the system version): " DOTNET_URL
    read -p "Enter the .NET application name: " APP_NAME
}

# Install PostgreSQL
install_postgresql() {
    if [ "$OS" == "rhel" ]; then
        sudo yum install -y postgresql-server postgresql-contrib || ERROR_OCCURRED=1
        if [ ! -d "/var/lib/pgsql/data" ] || [ -z "$(ls -A /var/lib/pgsql/data)" ]; then
            sudo postgresql-setup initdb || ERROR_OCCURRED=1
        else
            echo "PostgreSQL data directory already initialized, skipping."
        fi
        sudo systemctl start postgresql || ERROR_OCCURRED=1
        sudo systemctl enable postgresql || ERROR_OCCURRED=1
    elif [ "$OS" == "debian" ]; then
        sudo apt update || ERROR_OCCURRED=1
        sudo apt install -y postgresql postgresql-contrib || ERROR_OCCURRED=1
        sudo systemctl start postgresql || ERROR_OCCURRED=1
        sudo systemctl enable postgresql || ERROR_OCCURRED=1
    fi

    # Set up PostgreSQL database and user
    sudo -u postgres psql -c "CREATE DATABASE $DB_NAME;" || echo "Database $DB_NAME already exists."
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASSWORD';" || echo "User $DB_USER already exists."
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE $DB_NAME TO $DB_USER;" || ERROR_OCCURRED=1

    # Update pg_hba.conf for md5 authentication
    if [ "$OS" == "rhel" ]; then
        PG_HBA_CONF="/var/lib/pgsql/data/pg_hba.conf"
    elif [ "$OS" == "debian" ]; then
        PG_HBA_CONF="/etc/postgresql/$(ls /etc/postgresql)/main/pg_hba.conf"
    fi

    echo "Updating pg_hba.conf to use md5 authentication..."
    sudo sed -i "/^host\s\+all\s\+all\s\+127.0.0.1\/32\s\+ident/ s/ident/md5/" $PG_HBA_CONF || ERROR_OCCURRED=1
    sudo sed -i "/^host\s\+all\s\+all\s\+::1\/128\s\+ident/ s/ident/md5/" $PG_HBA_CONF || ERROR_OCCURRED=1

    echo "Verifying pg_hba.conf file..."
    grep "127.0.0.1" $PG_HBA_CONF
    grep "::1" $PG_HBA_CONF

    sudo systemctl restart postgresql || ERROR_OCCURRED=1
}

# Create .NET console application and EF Core setup
setup_dotnet_app() {
    cd "$(dirname "$0")" || ERROR_OCCURRED=1
    echo "Creating .NET console application..."
    dotnet new console -o "$APP_NAME" --force || { echo "Failed to create .NET application."; ERROR_OCCURRED=1; return; }
    cd "$APP_NAME" || ERROR_OCCURRED=1

    # Model.cs setup
    cat <<EOL > Model.cs
using System.Collections.Generic;
using Microsoft.EntityFrameworkCore;

public class BloggingContext : DbContext
{
    public DbSet<Blog> blogs { get; set; }
    public DbSet<Post> posts { get; set; }

    protected override void OnConfiguring(DbContextOptionsBuilder optionsBuilder)
        => optionsBuilder.UseNpgsql("host=localhost;database=$DB_NAME;user id=$DB_USER;password=$DB_PASSWORD;");
}

public class Blog
{
    public int blogid { get; set; }
    public string url { get; set; }
    public List<Post> Posts { get; set; }
}

public class Post
{
    public int postid { get; set; }
    public string title { get; set; }
    public string content { get; set; }
    public int blogid { get; set; }
    public Blog Blog { get; set; }
}
EOL

    # Program.cs setup
    cat <<EOL > Program.cs
using System;
using System.Linq;

public class Program
{
    public static void DumpDatabaseSnapshot(BloggingContext db)
    {
        var blogs = db.blogs.OrderBy(b => b.blogid).ToList();
        Console.WriteLine("Number of records = {0}", blogs.Count);
        foreach (var blog in blogs)
        {
            Console.WriteLine("BlogId = {0}, Url = {1}", blog.blogid, blog.url);
            if (blog.Posts != null)
            {
                foreach (var post in blog.Posts)
                {
                    Console.WriteLine("--> PostId = {0}, Title = {1}, Content = {2}", post.postid, post.title, post.content);
                }
            }
        }
    }

    public static void Main()
    {
        using var db = new BloggingContext();
        db.Add(new Blog { url = "http://example.com" });
        db.SaveChanges();
        DumpDatabaseSnapshot(db);

        var blog = db.blogs.First();
        blog.url = "https://example.com";
        blog.Posts = new List<Post> { new Post { title = "Sample Post", content = "This is a sample post content." } };
        db.blogs.Update(blog);
        db.SaveChanges();
        DumpDatabaseSnapshot(db);

        db.Remove(blog);
        db.SaveChanges();
        DumpDatabaseSnapshot(db);
    }
}
EOL

    # Adding EF Core packages and tools
    dotnet add package Npgsql.EntityFrameworkCore.PostgreSQL || ERROR_OCCURRED=1
    dotnet add package Microsoft.EntityFrameworkCore.Design || ERROR_OCCURRED=1
    dotnet new tool-manifest || ERROR_OCCURRED=1
    dotnet tool install dotnet-ef || ERROR_OCCURRED=1

    # Create migrations and update database
    dotnet ef migrations add InitialCreate || ERROR_OCCURRED=1
    dotnet ef database update || ERROR_OCCURRED=1
}

# Run the application and check if successful
run_application() {
    echo "Running the .NET application..."
    dotnet run

    if [ $? -eq 0 ]; then
        echo "Application ran successfully. Database connection was successful."
        ERROR_OCCURRED=0 
    else
        echo "Application failed to run."
        ERROR_OCCURRED=1  
    fi
}

# Wait for the log file to be written completely
wait_for_log_file() {
    local retries=5
    while [ ! -s "$LOG_FILE" ]; do
        echo "Waiting for the log file to be written..."
        sleep 1
        retries=$((retries - 1))
        if [ $retries -eq 0 ]; then
            echo "Log file is still empty after waiting."
            break
        fi
    done
}

# Send email results with execution status and log file content
send_email() {
    echo "Attempting to send email with execution status..."

    SUBJECT="Script Execution Results"
    TO="medhatiwari@ibm.com,Giridhar.Trivedi@ibm.com,Sanjam.Panda@ibm.com"

    wait_for_log_file

    if [ -f "$LOG_FILE" ]; then
        LOG_CONTENT=$(cat "$LOG_FILE")
    else
        LOG_CONTENT="Log file not found."
    fi

    if [ "$ERROR_OCCURRED" -eq 0 ]; then
        BODY="The script executed successfully. Below are the logs:\n\n$LOG_CONTENT"
    else
        BODY="The script encountered errors during execution. Below are the logs:\n\n$LOG_CONTENT"
    fi

    {
        echo "To: $TO"
        echo "Subject: $SUBJECT"
        echo
        echo -e "$BODY"
    } | sendmail -v "$TO"
    echo "Email sent successfully."
}

# Clean up all installed components, including migrations
cleanup() {
    echo "Cleaning up..."

    if [ "$OS" == "rhel" ]; then
        sudo systemctl stop postgresql
        sudo yum remove -y postgresql-server postgresql-contrib dotnet-sdk*
    elif [ "$OS" == "debian" ]; then
        sudo systemctl stop postgresql
        sudo apt remove -y postgresql postgresql-contrib dotnet-sdk*
    fi

    # Remove PostgreSQL data directory
    sudo rm -rf /var/lib/pgsql/data

    # Remove the created .NET application directory
    if [ -d "$(dirname "$0")/$APP_NAME" ]; then
        sudo rm -rf "$(dirname "$0")/$APP_NAME"
        echo "Removed .NET application: $APP_NAME"
    fi

    # Remove migrations folder if exists
    if [ -d "$APP_NAME/Migrations" ]; then
        rm -rf "$APP_NAME/Migrations"
        echo "Removed migrations folder."
    fi

    echo "Cleanup complete."
}

# Main script logic
detect_os
get_user_inputs
install_postgresql
setup_dotnet_app
run_application 

# Ensure that all commands have finished writing to the log before sending the email
send_email
cleanup

