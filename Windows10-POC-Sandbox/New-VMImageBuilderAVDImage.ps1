<#PSScriptInfo

.VERSION 1.0

.DATE 02-Jul-2023

.AUTHOR adrian.cojocaru@stefanini.com

#>

<#
  .SYNOPSIS
  Automate the customizations of an Azure Virtual Desktop image by using Azure VM Image Builder

  .DESCRIPTION
  https://learn.microsoft.com/en-us/azure/virtual-machines/windows/image-builder-virtual-desktop

  .INPUTS
  If your script accepts pipeline input, describe it here.

  .OUTPUTS
  output generated by your script. If any.

  .EXAMPLE

#>

# Step 1: Import module
Import-Module Az.Accounts

# Step 1.1 Connect-AzAccount :)
# Connect-AzAccount

#Region ----------------------------------------------------- [Set up the environment and variables] ----------------------------------------------
# Step 2: get existing context
$currentAzContext = Get-AzContext

# Destination image resource group
$imageResourceGroup="Sandbox-POC"

# Location (see possible locations in the main docs)
$location="westeurope"
New-AzResourceGroup -Name $imageResourceGroup -Location $location

# Your subscription. This command gets your current subscription
$subscriptionID=$currentAzContext.Subscription.Id

# Image template name
$imageTemplateName="Sandbox-W10-ImageTemplate-POC"

# Distribution properties object name (runOutput). Gives you the properties of the managed image on completion
$runOutputName="sigOutput"

# Create resource group
# New-AzResourceGroup -Name $imageResourceGroup -Location $location

#EndRegion ----------------------------------------------------- [Set up the environment and variables] ----------------------------------------------

#Region -------------------------------------------------------- [Permissions, user identity, and role] ----------------------------------------------
## Create a user identity
# setup role def names, these need to be unique
$timeInt=$(get-date -UFormat "%s")
#$imageRoleDefName="Azure Image Builder Image Def"+$timeInt
$imageRoleDefName="AIB-RBAC-AIB-AVD-Sandbox-POC"
#$identityName="aibIdentity"+$timeInt
$identityName="AIB-ManagedIdentity-AVD-Sandbox-POC"

## Add Azure PowerShell modules to support AzUserAssignedIdentity and Azure VM Image Builder
'Az.ImageBuilder', 'Az.ManagedServiceIdentity' | ForEach-Object {Install-Module -Name $_ -AllowPrerelease}

# Create the identity
New-AzUserAssignedIdentity -ResourceGroupName $imageResourceGroup -Name $identityName -Location $location

$identityNameResourceId=$(Get-AzUserAssignedIdentity -ResourceGroupName $imageResourceGroup -Name $identityName).Id
$identityNamePrincipalId=$(Get-AzUserAssignedIdentity -ResourceGroupName $imageResourceGroup -Name $identityName).PrincipalId

## Assign permissions to the identity to distribute images. The following commands download and update the template with the previously specified parameters.
$aibRoleImageCreationUrl="https://raw.githubusercontent.com/azure/azvmimagebuilder/main/solutions/12_Creating_AIB_Security_Roles/aibRoleImageCreation.json"
$aibRoleImageCreationPath = "aibRoleImageCreation-Sandbox-POC.json"

# Download the config
#Invoke-WebRequest -Uri $aibRoleImageCreationUrl -OutFile $aibRoleImageCreationPath -UseBasicParsing

((Get-Content -path $aibRoleImageCreationPath -Raw) -replace '<subscriptionID>',$subscriptionID) | Set-Content -Path $aibRoleImageCreationPath
((Get-Content -path $aibRoleImageCreationPath -Raw) -replace '<rgName>', $imageResourceGroup) | Set-Content -Path $aibRoleImageCreationPath
((Get-Content -path $aibRoleImageCreationPath -Raw) -replace 'Azure Image Builder Service Image Creation Role', $imageRoleDefName) | Set-Content -Path $aibRoleImageCreationPath

# Create a role definition
New-AzRoleDefinition -InputFile $aibRoleImageCreationPath

# Grant the role definition to the VM Image Builder service principal
New-AzRoleAssignment -ObjectId $identityNamePrincipalId -RoleDefinitionName $imageRoleDefName -Scope "/subscriptions/$subscriptionID/resourceGroups/$imageResourceGroup"
#EndRegion ----------------------------------------------------- [Permissions, user identity, and role] ----------------------------------------------

#Region ----------------------------------------------------- [Create an Azure Compute Gallery] ----------------------------------------------
## If you don't already have an Azure Compute Gallery, you need to create one.
$sigGalleryName= "Sandbox_W10_POC"
$imageDefName ="Sandbox_W10_POC"

# Create the gallery
New-AzGallery -GalleryName $sigGalleryName -ResourceGroupName $imageResourceGroup  -Location $location

# Create the gallery definition
New-AzGalleryImageDefinition -GalleryName $sigGalleryName -ResourceGroupName $imageResourceGroup -Location $location -Name $imageDefName -OsState generalized -OsType Windows -Publisher 'AdrianCojocaru' -Offer 'Windows' -Sku '10avd'

#EndRegion ----------------------------------------------------- [Create an Azure Compute Gallery] ----------------------------------------------

#Region -------------------------------------------------------- [Configure the VM Image Builder template] ----------------------------------------------
# Download and configure the template
# $templateUrl="https://raw.githubusercontent.com/azure/azvmimagebuilder/main/solutions/14_Building_Images_WVD/armTemplateWVD.json"
#$templateFilePath = "armTemplateWVD.json"
$templateFilePath = "armTemplateWVD.json"

#Invoke-WebRequest -Uri $templateUrl -OutFile $templateFilePath -UseBasicParsing

((Get-Content -path $templateFilePath -Raw) -replace '<subscriptionID>',$subscriptionID) | Set-Content -Path $templateFilePath
((Get-Content -path $templateFilePath -Raw) -replace '<rgName>',$imageResourceGroup) | Set-Content -Path $templateFilePath
((Get-Content -path $templateFilePath -Raw) -replace '<region>',$location) | Set-Content -Path $templateFilePath
((Get-Content -path $templateFilePath -Raw) -replace '<runOutputName>',$runOutputName) | Set-Content -Path $templateFilePath

((Get-Content -path $templateFilePath -Raw) -replace '<imageDefName>',$imageDefName) | Set-Content -Path $templateFilePath
((Get-Content -path $templateFilePath -Raw) -replace '<sharedImageGalName>',$sigGalleryName) | Set-Content -Path $templateFilePath
((Get-Content -path $templateFilePath -Raw) -replace '<imgBuilderId>',$identityNameResourceId) | Set-Content -Path $templateFilePath
#EndRegion ----------------------------------------------------- [Configure the VM Image Builder template] ----------------------------------------------

#Region -------------------------------------------------------- [Submit the template] ----------------------------------------------
# Your template must be submitted to the service.
# Doing so downloads any dependent artifacts, such as scripts, and validates, checks permissions, and stores them in the staging resource group, which is prefixed with IT_.
New-AzResourceGroupDeployment -ResourceGroupName $imageResourceGroup -TemplateFile $templateFilePath -TemplateParameterObject @{"api-Version" = "2020-02-14"; "imageTemplateName" = $imageTemplateName; "svclocation" = $location}

# Optional - if you have any errors running the preceding command, run:
$getStatus=$(Get-AzImageBuilderTemplate -ResourceGroupName $imageResourceGroup -Name $imageTemplateName)
$getStatus.ProvisioningErrorCode 
$getStatus.ProvisioningErrorMessage
#EndRegion ----------------------------------------------------- [Submit the template] ----------------------------------------------

#Region ----------------------------------------------------- [Build the image] ----------------------------------------------
Start-AzImageBuilderTemplate -ResourceGroupName $imageResourceGroup -Name $imageTemplateName -NoWait

# The command doesn't wait for the VM Image Builder service to complete the image build, so you can query the status as shown here.
$getStatus=$(Get-AzImageBuilderTemplate -ResourceGroupName $imageResourceGroup -Name $imageTemplateName)

# Shows all the properties
$getStatus | Format-List -Property *

# Shows the status of the build
$getStatus.LastRunStatusRunState 
$getStatus.LastRunStatusMessage
$getStatus.LastRunStatusRunSubState
#EndRegion -------------------------------------------------------- [Build the image] ----------------------------------------------
