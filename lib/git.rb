module RJGit

  import 'java.io.ByteArrayInputStream'
  import 'java.io.FileInputStream'

  import 'org.eclipse.jgit.lib.Constants'
  import 'org.eclipse.jgit.api.Git'
  import 'org.eclipse.jgit.api.AddCommand'
  import 'org.eclipse.jgit.api.RmCommand'
  import 'org.eclipse.jgit.transport.UsernamePasswordCredentialsProvider'
  import 'org.eclipse.jgit.transport.RefSpec'
  import 'org.eclipse.jgit.diff.RenameDetector'
  import 'org.eclipse.jgit.diff.DiffEntry'
  import 'org.eclipse.jgit.treewalk.filter.PathFilter'

  class RubyGit

    attr_accessor :jgit
    attr_accessor :jrepo

    RESET_MODES = ["HARD", "SOFT", "KEEP", "MERGE", "MIXED"]

    RJGit.delegate_to(Git, :@jgit)

    def initialize(repository)
      @jrepo = RJGit.repository_type(repository)
      @jgit = Git.new(@jrepo)
    end

    def log(path = nil, revstring = Constants::HEAD, options = {})
      ref = jrepo.resolve(revstring)
      return [] unless ref
      jcommits = Array.new
      
      if path && options[:follow]
        current_path = path    
        start = nil
        loop do
          logs = @jgit.log.add(ref).addPath(current_path).call
          logs.each do |jcommit|
            next if jcommits.include?(jcommit)
            jcommits << jcommit
            start = jcommit
          end
          current_path = follow_renames(start, current_path) if start
          break if current_path.nil?
        end
        
      else      
        logs = @jgit.log
        logs.add(ref)
        logs.addPath(path) if path
        logs.setMaxCount(options[:max_count]) if options[:max_count]
        logs.setSkip(options[:skip]) if options[:skip]
        # These options need tests
        # logs.addRange(options[:since], options[:until]) if (options[:since] && options[:until])
        # logs.not(options[:not]) if options[:not]
        jcommits = logs.call
      end
      
      jcommits.map{ |jcommit| Commit.new(jrepo, jcommit) }
    end

    def follow_renames(jcommit, path)
      commits = @jgit.log.add(jcommit).call
      commits.each do |jcommit_prev|
        tree_start = jcommit.getTree
        tree_prev  = jcommit_prev.getTree
        treewalk = TreeWalk.new(jrepo)
        #treewalk.setFilter(PathFilter.create(File.dirname(path)))
        treewalk.addTree(tree_prev)
        treewalk.addTree(tree_start)
        treewalk.setRecursive(true)
        rename_detector = RenameDetector.new(jrepo)
        rename_detector.addAll(DiffEntry.scan(treewalk))
        diff_entries = rename_detector.compute
        diff_entries.each do |entry|
          if ((entry.getChangeType == DiffEntry::ChangeType::RENAME || entry.getChangeType == DiffEntry::ChangeType::COPY) && entry.getNewPath.match(path))
            return entry.getOldPath
          end
        end
      end
      return nil
    end


    def branch_list
      branch = @jgit.branch_list
      array = Array.new
      branch.call.each do |b|
        array << b.get_name
      end
      array
    end

    def commit(message, options = {})
      commit_cmd = @jgit.commit.set_message(message)
      commit_cmd.set_all(options[:all]) unless options[:all].nil?
      commit_cmd.set_amend(options[:amend]) unless options[:amend].nil?
      commit_cmd.set_author(options[:author].person_ident) unless options[:author].nil?
      commit_cmd.set_committer(options[:committer].person_ident) unless options[:committer].nil?
      commit_cmd.set_insert_change_id(options[:insert_change_id]) unless options[:insert_change_id].nil?
      options[:only_paths].each {|path| commit_cmd.set_only(path)} unless options[:only_paths].nil?
      commit_cmd.set_reflog_comment(options[:reflog_comment]) unless options[:reflog_comment].nil?
      Commit.new(jrepo, commit_cmd.call)
    end

    def clone(remote, local, options = {})
      RubyGit.clone(remote, local, options)
    end

    def self.clone(remote, local, options = {})
      clone_command = Git.clone_repository
      clone_command.setURI(remote)
      clone_command.set_directory(java.io.File.new(local))
      clone_command.set_bare(true) if options[:is_bare]
      if options[:branch]
        if options[:branch] == :all
          clone_command.set_clone_all_branches(true)
        else
          clone_command.set_branch(options[:branch])
        end
      end
      if options[:username]
        clone_command.set_credentials_provider(UsernamePasswordCredentialsProvider.new(options[:username], options[:password]))
      end
      clone_command.call
      Repo.new(local)
    end

    def add(file_pattern)
      @jgit.add.add_filepattern(file_pattern).call
    end

    def remove(file_pattern)
      @jgit.rm.add_filepattern(file_pattern).call
    end

    def merge(commit)
      merge_command = @jgit.merge
      merge_command.include(commit.jcommit)
      result = merge_command.call
      if result.get_merge_status.to_string == 'Conflicting'
        return result.get_conflicts.to_hash.keys
      else
        return result
      end
    end

    def tag(name, message = "", commit_or_revision = nil, actor = nil, force = false)
      tag_command = @jgit.tag
      tag_command.set_name(name)
      tag_command.set_force_update(force)
      tag_command.set_message(message)
      tag_command.set_object_id(RJGit.commit_type(commit_or_revision)) if commit_or_revision
      if actor
        actor = RJGit.actor_type(actor)
        tag_command.set_tagger(actor)
      end
      tag_command.call
    end

    def resolve_tag(tagref)
      begin
        walk = RevWalk.new(@jrepo)
        walk.parse_tag(tagref.get_object_id)
      rescue Java::OrgEclipseJgitErrors::IncorrectObjectTypeException
        nil
      end
    end

    def create_branch(name)
      @jgit.branch_create.setName(name).call
    end

    def delete_branch(name)
      @jgit.branch_delete.set_branch_names(name).call
    end

    def rename_branch(old_name, new_name)
      @jgit.branch_rename.set_old_name(old_name).set_new_name(new_name).call
    end

    def checkout(branch_name = "master", options = {})
      checkout_command = @jgit.checkout.set_name(branch_name)
      checkout_command.set_start_point(options[:commit])
      options[:paths].each {|path| checkout_command.add_path(path)} if options[:paths]
      checkout_command.set_create_branch(true) if options[:create]
      checkout_command.set_force(true) if options[:force]
      result = {}
      begin
        checkout_command.call
        result[:success] = true
        result[:result] = @jgit.get_repository.get_full_branch
      rescue Java::OrgEclipseJgitApiErrors::CheckoutConflictException => conflict
        result[:success] = false
        result[:result] = conflict.get_conflicting_paths
      end
      result
    end

    def apply(input_stream)
      apply_result = @jgit.apply.set_patch(input_stream).call
      updated_files = apply_result.get_updated_files
      updated_files_parsed = []
      updated_files.each do |file|
        updated_files_parsed << file.get_absolute_path
      end
      updated_files_parsed
    end

    def apply_patch(patch_content)
      input_stream = ByteArrayInputStream.new(patch_content.to_java_bytes)
      apply(input_stream)
    end

    def apply_file(patch_file)
      input_stream = FileInputStream.new(patch_file)
      apply(input_stream)
    end

    def clean(options = {})
      clean_command = @jgit.clean
      clean_command.set_dry_run(true) if options[:dryrun]
      clean_command.set_paths(java.util.Arrays.asList(options[:paths])) if options[:paths]
      clean_command.call
    end

    def reset(ref, mode = "HARD", paths = nil)
      return nil if mode != nil && !RESET_MODES.include?(mode)
      reset_command = @jgit.reset
      if paths then
        paths.each do |path|
          reset_command.addPath(path)
        end
      end
      reset_command.setRef(ref.id)
      reset_command.setMode(org.eclipse.jgit.api.ResetCommand::ResetType.valueOf(mode)) unless mode == nil
      reset_command.call
    end

    def revert(commits)
      revert_command = @jgit.revert
      commits.each do |commit|
        revert_command.include commit.jcommit
      end
      Commit.new(jrepo, revert_command.call)
    end

    def status
      @jgit.status.call
    end

    def push_all(remote, options = {})
      push_command = @jgit.push
      push_command.set_dry_run(true) if options[:dryrun]
      push_command.set_remote(remote)
      push_command.set_push_all
      push_command.set_push_tags
      if options[:username]
        push_command.set_credentials_provider(UsernamePasswordCredentialsProvider.new(options[:username], options[:password]))
      end
      push_command.call
    end

    def push(remote = nil, refs = [], options = {})
      push_command = @jgit.push
      push_command.set_dry_run(true) if options[:dryrun]
      push_command.set_remote(remote) if remote
      if(refs.to_a.size > 0)
        refs.map!{|ref| RefSpec.new(ref)}
        push_command.set_ref_specs(refs)
      end
      if options[:username]
        push_command.set_credentials_provider(UsernamePasswordCredentialsProvider.new(options[:username], options[:password]))
      end
      push_command.call
    end

    def pull(remote = nil, remote_ref = nil, options = {})
      pull_command = @jgit.pull
      pull_command.set_dry_run(true) if options[:dryrun]
      pull_command.set_rebase(options[:rebase]) if options[:rebase]
      pull_command.set_remote(remote) if remote
      pull_command.set_remote_branch_name(remote_ref) if remote_ref
      if options[:username]
        pull_command.set_credentials_provider(UsernamePasswordCredentialsProvider.new(options[:username], options[:password]))
      end
      pull_command.call
    end

  end
end
