# AG-MoveLog
Sample Powershell script to Move Logs "en mass" for a SqlInstance which is protected by an availability Group.

For an Availability Group (AG), there are a few complexities to navigate such as:
- If a replica is a readable secondary we cant update the master files with new locations. 
- File locations cannot be modifed while sychronisation is in progres So we need to pause database HADR.
- We cant move files while the SqlInstance is running and we cant take database offline.


The sample script has a seven step process to automate moving log files en-mass with an Availability group. This is just a sample script so you would have to modify it for file locations and if you dont need all the steps

## Step 1 Get Primary Replica and Turn off readable secondaries on the replica to be moved
```powershell
 Write-Host "1. Turn OFF Read-Intent on replica"
   $primary_replica =  (Invoke-DbaQuery -SqlInstance  $Sqlinstance -Query "select primary_replica From sys.dm_hadr_availability_group_states").primary_replica
   $group_name =  (Invoke-DbaQuery -SqlInstance  $Sqlinstance -Query "select top 1 group_name From sys.dm_hadr_availability_replica_cluster_nodes WHERE replica_server_name ='$primary_replica'").group_name 
   $Query="ALTER AVAILABILITY GROUP [$group_name] MODIFY REPLICA ON N'$Sqlinstance' WITH (SECONDARY_ROLE(ALLOW_CONNECTIONS = NO))"
   Invoke-DbaQuery -SqlInstance   $primary_replica  -Query $Query
```


## Step 2 Update Logical Files in master_files
This process updates master_files and also outputs a powershell file that can be used to do the actual physcial move of the files once the instance is stopped (later stage)

```powershell
  ## 2. Move Logical Files in master_files and pause HADR
    Write-Host "2. Updating sys.master_files"
    $cmd=@()
    $psOutFile = "out-$Sqlinstance-move-ps.ps1"
    $sqlOutFile ="out-$Sqlinstance-move-sql.sql"
    if (Test-Path $psOutFile) {Remove-Item $psOutFile }
    if (Test-Path $sqlOutFile) {Remove-Item $sqlOutFile }


    Get-DbaDatabase -SqlInstance $Sqlinstance -ExcludeSystem | ForEach-Object {
        $Database = $_.Name

        if (!(Get-DbaAgDatabase -SqlInstance  $Sqlinstance -Database $Database | Select-Object -Property IsSuspended ).IsSuspended) {
            $Query = "ALTER DATABASE [$Database] SET HADR SUSPEND"
            Invoke-DbaQuery -SqlInstance  $Sqlinstance -Query $Query
         }


        
        $Query="select name, physical_name from sys.master_files where db_name(database_id) ='$Database' and type=1"
        $obj=Invoke-DbaQuery -SqlInstance  $Sqlinstance -Query $Query
        $obj | ForEach-Object {
            $name= $_.name
            $physical_name = $_.physical_name
            $file= Split-Path -Path $physical_name -Leaf
            $new_physical_name= Join-Path -Path $NewLogDir -ChildPath $file

            $cmd += "ROBOCOPY '$(Split-Path -Path $physical_name)' '$NewLogDir' '$file' /S /SEC /MOVE"
            
            $Query="ALTER DATABASE [$Database] MODIFY FILE ( NAME = N'$name', FILENAME = N'$new_physical_name');"
            $Query | Out-File -FilePath  $sqlOutFile  -Append            
            Invoke-DbaQuery -SqlInstance  $Sqlinstance -Query $Query
         }

    }
    $cmd | Out-File -FilePath  $psOutFile  -Append
```

## Step 3 Stop SQL Instance

```powershell
  if ( $SqlInstance.Split("\").Count -eq 1) {
        $Computer = $SqlInstance
        $Instance ="MSSQLSERVER"
     } else {
        $Computer =  $SqlInstance.Split("\")[0]
        $Instance = $SqlInstance.Split("\")[1]

     }
     Write-Host "3. Stopping SqlInstance $Instance"
     Stop-DbaService -Computer $Computer -Instance $Instance



## Step 4 Move Files from old to new location

```powershell
 Write-Host "4. RoboCopy Files (with SEC permissions )"
     & .\"$psOutFile" 
```

## Step 5 Restart SQL Instance

```powershell
    Write-Host "5. Restarting Services"
     Start-DbaService -Computer $Computer -Instance $Instance
```


## Step 6 Resume HADR
```powershell
 Write-Host "6. Resume HADR"
      Get-DbaDatabase -SqlInstance $Sqlinstance -ExcludeSystem | ForEach-Object {
        $Database = $_.Name
        $Query = "ALTER DATABASE [$Database] SET HADR RESUME"
        Invoke-DbaQuery -SqlInstance  $Sqlinstance -Query $Query     
     }
```


## Step 7  Turn back on Readable Secondary with Read Intent (may not need this)

```powershell
   Write-Host "7.  Turn ON  Readable Secondary with Read Intent"
   $Query="ALTER AVAILABILITY GROUP [$group_name] MODIFY REPLICA ON N'$Sqlinstance' WITH (SECONDARY_ROLE(ALLOW_CONNECTIONS = READ_ONLY))"
   Invoke-DbaQuery -SqlInstance   $primary_replica  -Query $Query
```

