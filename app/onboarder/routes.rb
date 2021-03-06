class Onboarder
  EMPTY = /\A\s*\z/
  include Messages

  get("/") do
    erb(:index)
  end

  post("/roles") do
    if params["role-name"] =~ EMPTY
      set_flash_failure(NEED_NONEMPTY_NAME)
      return redirect to("/")
    end

    @@db.transaction do
      role = Role.new({
        :name => params["role-name"],
        :user => params["user"],
      })

      @@db[:roles].delete_if { |r| r.name == role.name }
      @@db[:roles].push(role)
    end

    set_flash_success(sprintf("Successfully assigned %s as the %s.",
      user_login_to_pretty(params["user"]), params["role-name"]))

    redirect to("/")
  end

  delete("/roles") do
    if task_map.any? { |t| t.role == params["role-name"] }
      status(403)
      set_flash_failure(sprintf(
        "Please remove all of the tasks assigned to the %s role, first.",
        params["role-name"].inspect))
      redirect to("/")
    end

    @@db.transaction do
      @@db[:roles].delete_if { |r| r.name == params["role-name"] }
    end

    set_flash_success(sprintf(
      "Successfully removed the %s role.", params["role-name"].inspect))
    redirect to("/")
  end

  post("/newhire") do
    complain = proc do |msg|
      set_flash_failure(msg)
      status(403)
      erb(:index)
    end

    name_fields = [params["newhire-name-first"], params["newhire-name-last"]]
    date_fields = [params["newhire-startdate-year"],
      params["newhire-startdate-month"], params["newhire-startdate-day"]]

    if name_fields.any? { |n| n =~ EMPTY }
      return complain.call(NEED_NONEMPTY_NAME)
    end

    if params["newhire-klass"] =~ EMPTY
      return complain.call(NEED_NONEMPTY_DEPOT)
    end

    if date_fields.any? { |d| d =~ EMPTY }
      return complain.call(NEED_VALID_DATE)
    end

    begin
      if Time.new(*(date_fields.map { |x| x.to_i })) < Time.now
        return complain.call(NEED_FUTURE_DATE)
      end
    rescue ArgumentError
      return complain.call(NEED_VALID_DATE)
    end

    if !config(:default_redmine_proj) or config(:default_redmine_proj).empty?
      return complain.call(%q(
        Sorry, please define the Redmine project.
        <a href="#configuration">Click here.</a>
      ))
    end

    if !config(:hiring_manager) or config(:hiring_manager).empty?
      return complain.call(NEED_HIRING_MGR)
    end

    if !task_map or task_map.empty?
      return complain.call(NEED_TASK)
    end

    if !all_roles or all_roles.empty?
      return complain.call(NEED_ROLE)
    end

    newhire_fullname = sprintf("%s %s", params["newhire-name-first"],
      params["newhire-name-last"])

    parent_issue_subject = sprintf("Onboarding %s", newhire_fullname)
    uploads = []

    # Upload all of the attached files to the ticket.
    params["nfyles"].to_i.times do |i|
      fyle = params["fyle#{i}"]
      next if not fyle
      contents = fyle[:tempfile].read
      fname = fyle[:filename]

      ok, ret = @@redmine_cxn.post_attachment(contents)
      return complain.call(sprintf("%s: %s", fname, ret)) if !ok

      uploads.push({
        "token" => ret,
        "filename" => fname,
        "description" => "",
        "content_type" => Rack::Mime::MIME_TYPES[File.extname(fname)],
      })
    end

    # Post the parent issue
    parent_issue_id = @@redmine_cxn.post_issue({
      "project_id" => default_project_id,
      "subject" => parent_issue_subject,
      "description" => "Parent ticket for onboarding #{newhire_fullname}",
      "assigned_to_id" => user_login_to_id(config(:hiring_manager)),
      "due_date" => sprintf("%04d-%02d-%02d", *date_fields),
      "uploads" => uploads,
    })

    all_issue_ids = []
    all_issue_ids << parent_issue_id

    relevant_task_subjects = tasks_from_name(params["newhire-klass"])
    relevant_tasks = task_map.select { |t|
      relevant_task_subjects.include?(t.subject)
    }

    # Now post all of the "real" issues
    relevant_tasks.each do |task|
      issue_id = @@redmine_cxn.post_issue({
        "project_id" => default_project_id,
        "subject" => sprintf("%s - %s", newhire_fullname, task.subject),
        "description" => task.long_descr,
        "assigned_to_id" => user_login_to_id(find_role_obj(task.role).user),
        "parent_issue_id" => parent_issue_id,
        "due_date" => sprintf("%04d-%02d-%02d", *date_fields),
      })
      all_issue_ids << issue_id
    end

    set_flash_success(sprintf("Created issues %s", all_issue_ids.inspect))
    redirect to("/")
  end

  get("/config/?") do
    erb(:configuration)
  end

  post("/config") do
    @@db.transaction do
      conf = @@db[:config]
      conf[:default_redmine_proj] = params["default-redmine-proj"]
      conf[:hiring_manager] = params["hiring-manager"]
    end
    set_flash_success("Successfully updated.")
    redirect to("/config")
  end

  post("/tasks") do
    if params["task-name"] =~ EMPTY or params["role-name"] =~ EMPTY
      set_flash_failure("Sorry, please define a role first.")
      return erb(:"task_table")
    end

    @@db.transaction do
      newtask = Task.new({
        :subject => params["task-name"],
        :role => params["role-name"],
        :long_descr => params["long-descr"],
      })
      @@db[:tasks].delete_if { |t| t.subject == newtask.subject }
      @@db[:tasks].push(newtask)
    end

    set_flash_success(sprintf(
      "Task %s successfully added to the task map.",
      params["task-name"].inspect))
    redirect to("/tasktable")
  end

  delete("/tasks") do
    @@db.transaction do
      @@db[:tasks].delete_if { |t| t.subject == params["task-name"] }
    end

    set_flash_success(sprintf(
      "Successfully removed task %s from the task map.",
      params["task-name"].inspect))
    redirect to("/tasktable")
  end

  post("/taskmaps") do
    if params["taskmap-name"] =~ EMPTY
      set_flash_failure(NEED_NONEMTPY_NAME)
      status(403)
      return erb(:index)
    end

    @@db.transaction do
      if @@db[:taskmaps].any? { |tm| tm.name == params["taskmap-name"] }
        set_flash_failure(sprintf("Sorry, there already is a department %s",
          params["taskmap-name"].inspect))
        @@db.abort
      end
      tm = TaskMap.new({:name => params["taskmap-name"]})
      @@db[:taskmaps].push(tm)
      set_flash_success(sprintf("Successfully added department %s",
        tm.name.inspect))
    end

    redirect to("/")
  end

  get("/tasktable/?") do
    erb(:task_table)
  end

  # Currently, the strategy is to clear the entire list of tasks for each
  # class of employee, then re-populate it according to the HTML form.
  post("/tasktable") do
    @@db.transaction do
      @@db[:taskmaps].each { |tm| tm.tasks = [] }
      request.POST.each do |thang, _|
        split = thang.split("-", 2)
        tm_name = split[0]
        subject = split[1]
        tm = @@db[:taskmaps].detect { |t| t.name == tm_name }
        tm ? tm.tasks.push(subject) : next
      end
    end

    status(200)
    set_flash_success(UPDATE_TASKTABLE_SUCCESS)
    return erb(:task_table)
  end
end
