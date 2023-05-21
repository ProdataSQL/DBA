    $ErrorActionPreference = "Stop"
    $Sqlinstance ="LOCALHOST"
    $NewLogDir = "L:\Log"

    Set-Location  "S:\TEMP" #Location for Temp Script Files, CHange as needed
    

   ## 1. Get Primary Replica and Turn OFF readable Secondaries   
   Write-Host "1. Turn OFF Read-Intent on replica"
   $primary_replica =  (Invoke-DbaQuery -SqlInstance  $Sqlinstance -Query "select primary_replica From sys.dm_hadr_availability_group_states").primary_replica
   $group_name =  (Invoke-DbaQuery -SqlInstance  $Sqlinstance -Query "select top 1 group_name From sys.dm_hadr_availability_replica_cluster_nodes WHERE replica_server_name ='$primary_replica'").group_name 
   $Query="ALTER AVAILABILITY GROUP [$group_name] MODIFY REPLICA ON N'$Sqlinstance' WITH (SECONDARY_ROLE(ALLOW_CONNECTIONS = NO))"
   Invoke-DbaQuery -SqlInstance   $primary_replica  -Query $Query


    ## 2. Move Logical Files in master db
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

     ## 3. Stop Instance
     if ( $SqlInstance.Split("\").Count -eq 1) {
        $Computer = $SqlInstance
        $Instance ="MSSQLSERVER"
     } else {
        $Computer =  $SqlInstance.Split("\")[0]
        $Instance = $SqlInstance.Split("\")[1]

     }
     Write-Host "3. Stopping SqlInstance $Instance"
     Stop-DbaService -Computer $Computer -Instance $Instance


     ## 4. RoboCopy Files (with SEC permissions )
     Write-Host "4. RoboCopy Files (with SEC permissions )"
     & .\"$psOutFile" 


     ## 5. Restart 
     Write-Host "5. Restarting Services"
     Start-DbaService -Computer $Computer -Instance $Instance

     ## 6. Resume HADR
      Write-Host "6. Resume HADR"
      Get-DbaDatabase -SqlInstance $Sqlinstance -ExcludeSystem | ForEach-Object {
        $Database = $_.Name
        $Query = "ALTER DATABASE [$Database] SET HADR RESUME"
        Invoke-DbaQuery -SqlInstance  $Sqlinstance -Query $Query     
     }



   ## 7. Turn ON  Readable Secondary with Read Intent
   Write-Host "7.  Turn ON  Readable Secondary with Read Intent"
   $Query="ALTER AVAILABILITY GROUP [$group_name] MODIFY REPLICA ON N'$Sqlinstance' WITH (SECONDARY_ROLE(ALLOW_CONNECTIONS = READ_ONLY))"
   Invoke-DbaQuery -SqlInstance   $primary_replica  -Query $Query