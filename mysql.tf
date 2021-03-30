terraform {
  required_version = ">= 0.13"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 2.26"
    }
  }
}

provider "azurerm" {
  skip_provider_registration = true
  features {}
}

resource "azurerm_resource_group" "rg_mysql" {
	name     = "rg_mysql"
	location = "eastus"

	tags     = {
			"Environment" = "mysql"
	}
}

resource "azurerm_virtual_network" "vn_mysql" {
	name                = "vn_mysql"
	address_space       = ["10.0.0.0/16"]
	location            = "eastus"
	resource_group_name = azurerm_resource_group.rg_mysql.name
}

resource "azurerm_subnet" "subnet_mysql" {
	name                 = "subnet_mysql"
	resource_group_name  = azurerm_resource_group.rg_mysql.name
	virtual_network_name = azurerm_virtual_network.vn_mysql.name
	address_prefixes       = ["10.0.1.0/24"]
}

resource "azurerm_public_ip" "public_ip_mysql" {
	name                         = "public_ip_mysql"
	location                     = "eastus"
	resource_group_name          = azurerm_resource_group.rg_mysql.name
	allocation_method            = "Static"
}

resource "azurerm_network_security_group" "nsg_mysql" {
	name                = "nsg_mysql"
	location            = "eastus"
	resource_group_name = azurerm_resource_group.rg_mysql.name

	security_rule {
		name                       = "mysql"
		priority                   = 1001
		direction                  = "Inbound"
		access                     = "Allow"
		protocol                   = "Tcp"
		source_port_range          = "*"
		destination_port_range     = "3306"
		source_address_prefix      = "*"
		destination_address_prefix = "*"
	}

	security_rule {
		name                       = "SSH"
		priority                   = 1002
		direction                  = "Inbound"
		access                     = "Allow"
		protocol                   = "Tcp"
		source_port_range          = "*"
		destination_port_range     = "22"
		source_address_prefix      = "*"
		destination_address_prefix = "*"
	}
}

resource "azurerm_network_interface" "nic_mysql" {
	name                      = "nic_mysql"
	location                  = "eastus"
	resource_group_name       = azurerm_resource_group.rg_mysql.name

	ip_configuration {
		name                          = "myNicConfiguration"
		subnet_id                     = azurerm_subnet.subnet_mysql.id
		private_ip_address_allocation = "Dynamic"
		public_ip_address_id          = azurerm_public_ip.public_ip_mysql.id
	}
}

resource "azurerm_network_interface_security_group_association" "example" {
	network_interface_id      = azurerm_network_interface.nic_mysql.id
	network_security_group_id = azurerm_network_security_group.nsg_mysql.id
}

data "azurerm_public_ip" "ip_aula_data_db" {
  name                = azurerm_public_ip.public_ip_mysql.name
  resource_group_name = azurerm_resource_group.rg_mysql.name
}

resource "azurerm_storage_account" "sam_sql" {
	name                        = "storageaccountmyvm"
	resource_group_name         = azurerm_resource_group.rg_mysql.name
	location                    = "eastus"
	account_tier                = "Standard"
	account_replication_type    = "LRS"
}

resource "azurerm_linux_virtual_machine" "vm_mysql" {
	name                  = "mysql"
	location              = "eastus"
	resource_group_name   = azurerm_resource_group.rg_mysql.name
	network_interface_ids = [azurerm_network_interface.nic_mysql.id]
	size                  = "Standard_DS1_v2"

	os_disk {
		name              = "myOsDiskMySQL"
		caching           = "ReadWrite"
		storage_account_type = "Premium_LRS"
	}

	source_image_reference {
		publisher = "Canonical"
		offer     = "UbuntuServer"
		sku       = "18.04-LTS"
		version   = "latest"
	}

	computer_name  = "myvm"
	admin_username = var.user
	admin_password = var.password
	disable_password_authentication = false

	boot_diagnostics {
		storage_account_uri = azurerm_storage_account.sam_sql.primary_blob_endpoint
	}

	depends_on = [ azurerm_resource_group.rg_mysql ]
}

output "public_ip_address_mysql" {
  value = azurerm_public_ip.public_ip_mysql.ip_address
}

resource "time_sleep" "wait_30_seconds_db" {
  depends_on = [azurerm_linux_virtual_machine.vm_mysql]
  create_duration = "30s"
}

resource "null_resource" "upload_db" {
	provisioner "file" {
		connection {
			type = "ssh"
			user = var.user
			password = var.password
			host = data.azurerm_public_ip.ip_aula_data_db.ip_address
		}
		source = "config"
		destination = "/home/azureuser"
	}

	depends_on = [ time_sleep.wait_30_seconds_db ]
}

resource "null_resource" "deploy_db" {
	triggers = {
			order = null_resource.upload_db.id
	}
	provisioner "remote-exec" {
		connection {
			type = "ssh"
			user = var.user
			password = var.password
			host = data.azurerm_public_ip.ip_aula_data_db.ip_address
		}
		inline = [
			"sudo apt-get update",
			"sudo apt-get install -y mysql-server-5.7",
			"sudo cp -f /home/azureuser/config/mysqld.cnf /etc/mysql/mysql.conf.d/mysqld.cnf",
			"sudo service mysql restart",
			"sleep 20"
		]
	}
}
